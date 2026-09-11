#if canImport(UIKit)
    import Darwin
    import Foundation
    import Network
    import XCTest
    import dnssd
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

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

        /// Lets a test's bridge fake answer with the attachment snapshot naming the model's own client the
        /// owner, which only exists once the model does.
        private actor AttachmentSnapshotHolder {
            private var snapshot = TerminalSessionAttachmentSnapshot()

            func set(_ snapshot: TerminalSessionAttachmentSnapshot) { self.snapshot = snapshot }

            func current() -> TerminalSessionAttachmentSnapshot { snapshot }
        }

        /// Lets a test install the response its bridge client should serve after the model that owns that
        /// client exists — the response has to be built from the model's own client identity.
        private actor TerminalStateResponseHolder {
            private var response = SpacesDeviceAPIResponse(ok: false, message: "no state installed")

            func set(_ response: SpacesDeviceAPIResponse) { self.response = response }

            func current() -> SpacesDeviceAPIResponse { response }
        }

        /// A `.state` mock whose first read is held open until the test releases it, so a fetch can still
        /// be in flight while the payloads that arrive behind it fail to reduce. Every later read answers
        /// immediately with `later`.
        private actor HeldTerminalStateResponder {
            private let first: SpacesDeviceAPIResponse
            private let later: SpacesDeviceAPIResponse
            private var answeredCount = 0
            private var isReleased = false
            private var waiter: CheckedContinuation<Void, Never>?

            init(first: SpacesDeviceAPIResponse, later: SpacesDeviceAPIResponse) {
                self.first = first
                self.later = later
            }

            func answer() async -> SpacesDeviceAPIResponse {
                answeredCount += 1
                guard answeredCount == 1 else { return later }
                if !isReleased { await withCheckedContinuation { waiter = $0 } }
                return first
            }

            func release() {
                isReleased = true
                waiter?.resume()
                waiter = nil
            }
        }

        private actor HeldHeartbeatResponder {
            private var didStart = false
            private var isReleased = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func markStarted() {
                didStart = true
                let waiters = startWaiters
                startWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }

            func waitForStart() async {
                guard !didStart else { return }
                await withCheckedContinuation { continuation in startWaiters.append(continuation) }
            }

            func waitForRelease() async {
                guard !isReleased else { return }
                await withCheckedContinuation { continuation in releaseWaiters.append(continuation) }
            }

            func release() {
                isReleased = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }

        private actor HeldTakeoverResponder {
            private var didStart = false
            private var isReleased = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func waitForReleaseAfterStarting() async {
                didStart = true
                let waiters = startWaiters
                startWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                guard !isReleased else { return }
                await withCheckedContinuation { continuation in releaseWaiters.append(continuation) }
            }

            func waitForStart() async {
                guard !didStart else { return }
                await withCheckedContinuation { continuation in startWaiters.append(continuation) }
            }

            func release() {
                isReleased = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }

        private actor HeldResizeResponder {
            private var resizeCount = 0
            private var didStart = false
            private var isReleased = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            /// Holds only the first resize request open; a later one (the coalesced follow-up's own
            /// resize, in particular) answers immediately, matching a daemon that is free to serve it.
            func waitForFirstResizeThenRelease() async {
                resizeCount += 1
                guard resizeCount == 1 else { return }
                didStart = true
                let waiters = startWaiters
                startWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                guard !isReleased else { return }
                await withCheckedContinuation { continuation in releaseWaiters.append(continuation) }
            }

            func waitForFirstResizeStart() async {
                guard !didStart else { return }
                await withCheckedContinuation { continuation in startWaiters.append(continuation) }
            }

            func release() {
                isReleased = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }

        private actor HeldFirstAttachResponder {
            private var attachCount = 0
            private var didStart = false
            private var isReleased = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func waitForFirstAttachThenRelease() async {
                attachCount += 1
                guard attachCount == 1 else { return }
                didStart = true
                let waiters = startWaiters
                startWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                guard !isReleased else { return }
                await withCheckedContinuation { continuation in releaseWaiters.append(continuation) }
            }

            /// Whether the held attach has been answered, so a responder can model the daemon: a heartbeat
            /// for this client is `not found` only until its attach completes.
            var hasReleased: Bool { isReleased }

            func waitForFirstAttachStart() async {
                guard !didStart else { return }
                await withCheckedContinuation { continuation in startWaiters.append(continuation) }
            }

            func release() {
                isReleased = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }

        /// Holds the first key input open, then fails it with `CancellationError` — what the real client's
        /// in-flight request throws when the viewer's stop cancels the task running it. The closure backend
        /// the tests use never observes task cancellation itself, so the failure is injected by hand.
        private actor HeldCancelledInputSendResponder {
            private var keyCount = 0
            private var didStart = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func waitForFirstKeyThenFailWithCancellation() async throws {
                keyCount += 1
                guard keyCount == 1 else { return }
                didStart = true
                let waiters = startWaiters
                startWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                await withCheckedContinuation { continuation in releaseWaiters.append(continuation) }
                throw CancellationError()
            }

            func waitForFirstKeyStart() async {
                guard !didStart else { return }
                await withCheckedContinuation { continuation in startWaiters.append(continuation) }
            }

            func failWithCancellation() {
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }

        private actor HeldConnectLifecycleBackend: SpacesDeviceAPIBackend {
            private let stateResponse: SpacesDeviceAPIResponse
            private var attachCount = 0
            private var isFirstAttachReleased = false
            private var didStartFirstAttach = false
            private var firstAttachWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
            private var subscribeCount = 0
            private var subscribeWaiters: [CheckedContinuation<Void, Never>] = []

            init(stateResponse: SpacesDeviceAPIResponse) { self.stateResponse = stateResponse }

            nonisolated func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport { HeldConnectLifecycleRequestTransport(backend: self) }

            nonisolated func openSessionStream(
                request: SpacesDeviceAPIRequest, initialEventTimeout: Duration,
                onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
                onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
            ) async throws -> SpacesDeviceAPIStreamHandle {
                await recordSubscribe()
                return SpacesDeviceAPIStreamHandle {}
            }

            func send(_ request: SpacesDeviceAPIRequest) async -> SpacesDeviceAPIResponse {
                if case .terminalControl(let payload) = request.command, payload.action == .attach {
                    attachCount += 1
                    if attachCount == 1 {
                        didStartFirstAttach = true
                        let waiters = firstAttachWaiters
                        firstAttachWaiters.removeAll()
                        for waiter in waiters { waiter.resume() }
                        guard !isFirstAttachReleased else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                        await withCheckedContinuation { continuation in releaseWaiters.append(continuation) }
                    }
                }
                if case .state = request.command { return stateResponse }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func waitForFirstAttachStart() async {
                guard !didStartFirstAttach else { return }
                await withCheckedContinuation { continuation in firstAttachWaiters.append(continuation) }
            }

            func waitForSubscribeCount(_ count: Int) async {
                guard subscribeCount < count else { return }
                await withCheckedContinuation { continuation in subscribeWaiters.append(continuation) }
            }

            func releaseFirstAttach() {
                isFirstAttachReleased = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }

            func currentSubscribeCount() -> Int { subscribeCount }

            private func recordSubscribe() {
                subscribeCount += 1
                let waiters = subscribeWaiters
                subscribeWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }

        private struct HeldConnectLifecycleRequestTransport: SpacesDeviceAPIRequestTransport {
            let backend: HeldConnectLifecycleBackend

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse { await backend.send(request) }

            func close() async {}
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

            func countStateRequests() -> Int { stateRequests().count }

            /// The `.state` reads in the order they were sent, so a test can inspect what each one asked
            /// the daemon for.
            func stateRequests() -> [SpacesDeviceTerminalSessionRequest] {
                requests.compactMap { request in
                    guard case .state(let payload) = request.command else { return nil }
                    return payload
                }
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

            func count() -> Int { messages.count }
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

        /// The connect bootstrap read is the only `.state` read that asks the daemon for no screen: the
        /// subscription it is issued alongside delivers the session's frame, so asking here would move the
        /// identical frame twice on every open. Every other read is itself what brings the screen.
        func testTheConnectBootstrapReadAsksForNoRenderUpdate() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didRead = try await waitForStateRequestCount(1, recorder: recorder)
            XCTAssertTrue(didRead, "the open must issue its bootstrap read")
            let reads = await recorder.stateRequests()
            XCTAssertEqual(reads.map(\.includesRenderUpdate), [false], "the bootstrap read must ask for the session's metadata alone")
        }

        /// The control counterpart. A takeover is the one state-carrying control this viewer wants answered
        /// without a screen: it holds its first paint until a frame at its own grid arrives, and the frame
        /// for the epoch the transfer opens reaches it as the `attachment_state` broadcast. Attach keeps the
        /// screen, as every other state-carrying control does, and the Mac's paired-device pane keeps it on
        /// a takeover too, which is why the request carries the choice rather than the daemon deciding by
        /// action.
        func testTheTakeoverAsksForNoRenderUpdate() async throws {
            let recorder = DeviceAPIRequestRecorder()
            // The bootstrap read reports a session another device owns, which is what makes the open
            // attempt the automatic takeover this test asserts on.
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .state = request.command else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                return Self.terminalStateResponse(Self.ownedState(clientID: "mac-owner", emittedAt: "2026-06-04T14:23:30Z"))
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didTakeOver = try await waitForTerminalControlAction(.takeover, count: 1, recorder: recorder)
            XCTAssertTrue(didTakeOver, "an open must attempt the takeover this asserts on")
            let requests = await recorder.snapshot()
            let controls = requests.compactMap { request -> SpacesDeviceTerminalControlRequest? in
                guard case .terminalControl(let payload) = request.command else { return nil }
                return payload
            }
            XCTAssertEqual(
                controls.first { $0.action == .takeover }?.includesRenderUpdate, false,
                "the takeover's acknowledgment must cost the session no screen export")
            XCTAssertEqual(
                controls.first { $0.action == .attach }?.includesRenderUpdate, true, "every other state-carrying control is answered with the screen")
        }

        /// The counterpart to the bootstrap read: an ended session's state load has no stream behind it at
        /// all, so its read is the only thing that can bring the final screen and must ask for it.
        func testTheEndedStateReadAsksForTheRenderUpdate() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(state: .exited), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didRead = try await waitForStateRequestCount(1, recorder: recorder)
            XCTAssertTrue(didRead, "an ended session must load its final state")
            let reads = await recorder.stateRequests()
            XCTAssertEqual(reads.map(\.includesRenderUpdate), [true], "a read nothing else feeds must ask for the screen")
        }

        func testEndedTerminalDoesNotPerformForegroundOwnershipEvaluation() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(state: .exited), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            try await Task.sleep(for: .milliseconds(100))

            let requests = await recorder.snapshot()
            XCTAssertTrue(requests.isEmpty, "ended terminals must not renew attachment, fetch state, or take over on foreground")
        }

        func testForegroundResumeStartingStateKeepsAutomaticTakeoverEligibleForRunning() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:25:00Z", state: .starting))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            let didReadState = try await waitForTerminalControlAction(.heartbeat, count: 1, recorder: recorder)
            XCTAssertTrue(didReadState, "foreground resume must accept the starting state its heartbeat answers with")
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:00Z"),
                isOutOfBand: false)

            let didTakeOver = try await waitForTerminalControlAction(.takeover, count: 1, recorder: recorder)
            XCTAssertTrue(didTakeOver, "the later running state must retain normal automatic takeover eligibility")
        }

        func testForegroundResumeDoesNotAttachAfterBackgroundingAgainDuringHeartbeat() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let heartbeat = HeldHeartbeatResponder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    await heartbeat.markStarted()
                    await heartbeat.waitForRelease()
                    return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            await heartbeat.waitForStart()
            model.prepareForBackgrounding()
            await heartbeat.release()
            try await Task.sleep(for: .milliseconds(100))

            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(attachCount, 0, "a superseded foreground cycle must not reattach after its heartbeat returns")
        }

        func testBackgroundStartingToRunningWaitsForForegroundOwnershipEvaluation() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:00Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.prepareForBackgrounding()
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:25:00Z"),
                isOutOfBand: false)
            try await Task.sleep(for: .milliseconds(100))
            let backgroundTakeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(backgroundTakeoverCount, 0, "a background state must not preempt another owner before foreground evaluation")

            model.resumeAfterBackgrounding()
            let didTakeOver = try await waitForTerminalControlAction(.takeover, count: 1, recorder: recorder)
            XCTAssertTrue(didTakeOver, "the fresh foreground state must take the single automatic ownership path")
        }

        /// A detail can mount while its scene is inactive, before SwiftUI emits any phase change. Its
        /// initial lifecycle synchronization arms the same foreground evaluation as a later background
        /// transition, so a running stream payload cannot take ownership until the scene is active.
        func testInitiallyInactiveViewerWaitsForActivationBeforeAutomaticTakeover() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:00Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            // This is the detail's initial-task ordering for a scene that mounted inactive.
            model.prepareForBackgrounding()
            model.start()
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:25:00Z"),
                isOutOfBand: false)
            try await Task.sleep(for: .milliseconds(100))
            let inactiveTakeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(inactiveTakeoverCount, 0, "an initially inactive detail must not take over from its stream")

            model.resumeAfterBackgrounding()
            let didReadState = try await waitForTerminalControlAction(.heartbeat, count: 1, recorder: recorder)
            XCTAssertTrue(didReadState, "activation must make one fresh ownership read")
            let didTakeOver = try await waitForTerminalControlAction(.takeover, count: 1, recorder: recorder)
            XCTAssertTrue(didTakeOver, "the fresh active result must take over once")
            try await Task.sleep(for: .milliseconds(100))
            let activeTakeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(activeTakeoverCount, 1, "the initial foreground cycle must stay bounded to one takeover")
        }

        /// A retained detail can stop while backgrounded and remount after the scene is already active,
        /// so it has no later phase transition to arm its ownership read. Starting that replacement
        /// lifecycle must still consume one fresh foreground result.
        func testActiveRemountAfterBackgroundedStopPerformsForegroundOwnershipEvaluation() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:27:00Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.prepareForBackgrounding()
            model.stop()
            model.start()
            model.resumeAfterBackgrounding()

            let didReadState = try await waitForTerminalControlAction(.heartbeat, count: 1, recorder: recorder)
            XCTAssertTrue(didReadState, "an active remount must make one fresh ownership read")
            let didTakeOver = try await waitForTerminalControlAction(.takeover, count: 1, recorder: recorder)
            XCTAssertTrue(didTakeOver, "the authoritative remount result must restore automatic takeover")
        }

        /// A heartbeat can report that the live lease ended because the terminal exited during suspension.
        /// The authoritative state read still carries the final terminal state, so it must run before the
        /// foreground cycle is consumed and must not take ownership of an ended session.
        func testForegroundHeartbeatSessionNotRunningReadsAndAppliesFinalTerminalState() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let finalState = Self.runState(
                childPID: 200, state: .exited, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-04T14:27:00Z")
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return SpacesDeviceAPIResponse(ok: false, message: "The terminal session is not running.", errorCode: .sessionNotRunning)
                }
                if case .state = request.command { return Self.terminalStateResponse(finalState) }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()

            let didReadState = try await waitForStateRequestCount(1, recorder: recorder)
            XCTAssertTrue(didReadState, "a non-running heartbeat must still fetch the final terminal state")
            await waitUntil("the final terminal state to apply") { model.renderMode == "ended" }
            XCTAssertEqual(model.latestState?.runtimeState?.state, .exited)
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 0, "an ended foreground state must never take over")
        }

        /// A terminal detail pauses overview polling, and its existing state stream can remain open after
        /// the daemon revokes this device. The foreground heartbeat is therefore responsible for routing
        /// that authentication failure into the normal re-pair recovery path.
        func testForegroundHeartbeatAuthenticationFailureRequestsRePairing() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let authenticationRecorder = AuthenticationPromptRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return SpacesDeviceAPIResponse(ok: false, message: "Invalid device auth token.", errorCode: .unauthorized)
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(),
                onAuthenticationRequired: { message in Task { await authenticationRecorder.append(message) } }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()

            let authenticationMessage = try await waitForAuthenticationMessage(recorder: authenticationRecorder)
            XCTAssertEqual(authenticationMessage, "This Mac no longer recognizes this device. Open Devices and pair this device again.")
            let stateRequestCount = await recorder.countStateRequests()
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            let promptCount = await authenticationRecorder.count()
            XCTAssertEqual(stateRequestCount, 0, "a revoked client must not continue into the foreground state read")
            XCTAssertEqual(takeoverCount, 0)
            XCTAssertEqual(promptCount, 1, "one revoked heartbeat must request re-pairing exactly once")
        }

        func testForegroundStreamStateWaitsForPendingHeartbeatEvaluation() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let heartbeat = HeldHeartbeatResponder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    await heartbeat.markStarted()
                    await heartbeat.waitForRelease()
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:00Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            await heartbeat.waitForStart()
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:25:00Z"),
                isOutOfBand: false)
            try await Task.sleep(for: .milliseconds(100))
            let beforeReadTakeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(beforeReadTakeoverCount, 0, "a stream update must not consume foreground ownership intent before its heartbeat answers")

            await heartbeat.release()
            let didTakeOver = try await waitForTerminalControlAction(.takeover, count: 1, recorder: recorder)
            XCTAssertTrue(didTakeOver, "the fresh foreground read must decide the one automatic takeover")
        }

        func testForegroundResumeUsesNewerAcceptedStreamStateWhenItsReadIsRefused() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let staleResponse = Self.terminalStateResponse(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:25:00Z"))
            let responder = HeldTerminalStateResponder(first: staleResponse, later: staleResponse)
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat { return await responder.answer() }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            let didStartRead = try await waitForTerminalControlAction(.heartbeat, count: 1, recorder: recorder)
            XCTAssertTrue(didStartRead, "foreground resume must issue its state-carrying heartbeat")
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:00Z"),
                isOutOfBand: false)
            await responder.release()

            let didTakeOver = try await waitForTerminalControlAction(.takeover, count: 1, recorder: recorder)
            XCTAssertTrue(didTakeOver, "the state accepted from the newer stream must settle the bounded foreground evaluation")
            try await Task.sleep(for: .milliseconds(100))
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 1, "the superseding stream state must produce only one foreground takeover")
        }

        func testStoppedForegroundStateReadCannotApplyIntoReplacementLifecycle() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let responder = HeldTerminalStateResponder(
                first: Self.terminalStateResponse(
                    Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:00Z")),
                later: Self.terminalStateResponse(
                    Self.runningTerminalState(
                        attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:25:00Z", state: .starting)))
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .state = request.command { return await responder.answer() }
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat { return await responder.answer() }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            let didStartForegroundRead = try await waitForTerminalControlAction(.heartbeat, count: 1, recorder: recorder)
            XCTAssertTrue(didStartForegroundRead, "foreground resume must have its state-carrying heartbeat in flight")

            model.stop()
            model.start()
            let didStartReplacementRead = try await waitForStateRequestCount(1, recorder: recorder)
            XCTAssertTrue(didStartReplacementRead, "the replacement lifecycle must begin its own bootstrap read")
            await responder.release()
            try await Task.sleep(for: .milliseconds(100))

            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 0, "a stopped lifecycle's state response must not arm takeover for its replacement")
        }

        func testStoppedRenderResyncReadCannotApplyIntoReplacementLifecycle() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let responder = HeldTerminalStateResponder(
                first: Self.terminalStateResponse(
                    Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:00Z")),
                later: Self.terminalStateResponse(
                    Self.runningTerminalState(
                        attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:25:00Z", state: .starting)))
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .state = request.command { return await responder.answer() }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await model.applyLatestState(
                try Self.unappliableDeltaState(baseRevision: 40, targetRevision: 41, ownerEpoch: 1, emittedAt: "2026-06-04T14:25:00Z"),
                isOutOfBand: false)
            let didStartResyncRead = try await waitForStateRequestCount(1, recorder: recorder)
            XCTAssertTrue(didStartResyncRead, "a failed render update must begin its resync read")

            model.stop()
            model.start()
            let didStartReplacementRead = try await waitForStateRequestCount(2, recorder: recorder)
            XCTAssertTrue(didStartReplacementRead, "the replacement lifecycle must bootstrap independently")
            await responder.release()
            try await Task.sleep(for: .milliseconds(100))

            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 0, "a stopped resync response must not arm takeover for its replacement")
        }

        func testStopWaitsForInFlightAutomaticTakeoverBeforeDetaching() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let takeover = HeldTakeoverResponder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:25:00Z"))
                }
                if case .terminalControl(let payload) = request.command, payload.action == .takeover { await takeover.waitForReleaseAfterStarting() }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            await takeover.waitForStart()
            model.stop()
            try await Task.sleep(for: .milliseconds(100))
            let detachBeforeTakeoverSettles = await recorder.countTerminalControlAction(.detach)
            XCTAssertEqual(detachBeforeTakeoverSettles, 0, "stop must not detach before an automatic takeover in flight has settled")

            await takeover.release()
            let didDetach = try await waitForTerminalControlAction(.detach, count: 1, recorder: recorder)
            XCTAssertTrue(didDetach, "stop must detach after the automatic takeover response settles")
        }

        /// A foreground resume while the reconnect's viewer attach is still in flight must end with one
        /// attach. The resume heartbeat rides the same command channel as the attach, so it is answered
        /// only after the attach completes, and the daemon then knows the client: the resume must not
        /// reattach on top of that.
        func testForegroundResumeDoesNotReattachOverAnInFlightReconnectViewerAttach() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let heldAttach = HeldFirstAttachResponder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .attach {
                    await heldAttach.waitForFirstAttachThenRelease()
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    // The daemon answers a heartbeat for a client it has not attached with not-found; once
                    // the attach has been answered the client exists.
                    guard await heldAttach.hasReleased else {
                        return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                    }
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:25:00Z"))
                }
                if case .state = request.command {
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:25:00Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            await heldAttach.waitForFirstAttachStart()
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            let startedSecondAttach = try await waitForTerminalControlAction(.attach, count: 2, recorder: recorder)
            XCTAssertFalse(startedSecondAttach, "foreground resume must not start a second attach while the reconnect's attach is in flight")

            await heldAttach.release()
            let didTakeOver = try await waitForTerminalControlAction(.takeover, count: 1, recorder: recorder)
            XCTAssertTrue(didTakeOver, "the reconnect's attach must settle before the foreground ownership decision")
            let requests = await recorder.snapshot()
            let attachCount = requests.filter { request in
                guard case .terminalControl(let payload) = request.command else { return false }
                return payload.action == .attach
            }.count
            XCTAssertEqual(attachCount, 1)
        }

        func testStoppedConnectCannotSubscribeIntoTheRestartedViewerLifecycle() async throws {
            let stateResponse = Self.terminalStateResponse(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:25:00Z", state: .starting))
            let backend = HeldConnectLifecycleBackend(stateResponse: stateResponse)
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            await backend.waitForFirstAttachStart()
            model.stop()
            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.releaseFirstAttach()
            try await Task.sleep(for: .milliseconds(100))

            let subscribeCount = await backend.currentSubscribeCount()
            XCTAssertEqual(subscribeCount, 1, "the stopped connect must not subscribe or install callbacks into the restarted lifecycle")
        }

        func testStopWaitsForInFlightForegroundViewerAttachThenDetachesIt() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let heldAttach = HeldFirstAttachResponder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                }
                if case .terminalControl(let payload) = request.command, payload.action == .attach {
                    await heldAttach.waitForFirstAttachThenRelease()
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            await heldAttach.waitForFirstAttachStart()
            model.stop()
            await heldAttach.release()

            let didDetach = try await waitForTerminalControlAction(.detach, count: 1, recorder: recorder)
            XCTAssertTrue(didDetach, "stop must detach an attach that completed after stop began")
            let requests = await recorder.snapshot()
            let attachIndex = requests.firstIndex { request in
                guard case .terminalControl(let payload) = request.command else { return false }
                return payload.action == .attach
            }
            let detachIndex = requests.firstIndex { request in
                guard case .terminalControl(let payload) = request.command else { return false }
                return payload.action == .detach
            }
            XCTAssertNotNil(attachIndex)
            XCTAssertNotNil(detachIndex)
            if let attachIndex, let detachIndex { XCTAssertLessThan(attachIndex, detachIndex) }
        }

        func testBackNavigationDoesNotSurfaceTheInputSendItCancelled() async throws {
            let heldSend = HeldCancelledInputSendResponder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                if case .terminalControl(let payload) = request.command, payload.action == .key {
                    try await heldSend.waitForFirstKeyThenFailWithCancellation()
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await model.sendKey("enter")
            await heldSend.waitForFirstKeyStart()
            XCTAssertNil(model.errorMessage, "an input send that is still in flight must not surface anything on its own")

            await model.prepareForBackNavigation()
            XCTAssertNil(model.errorMessage, "beginning the back navigation must not surface anything")
            await heldSend.failWithCancellation()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNil(model.errorMessage, "leaving the terminal view must not surface the input send that its own exit cancelled")
        }

        func testForegroundResumeReclaimsALeaseExpiredOwner() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .state = request.command {
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:25:00Z"))
                }
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                }
                guard case .terminalControl(let payload) = request.command, payload.action == .takeover, let clientID = payload.clientID else {
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                let client = TerminalClient(
                    id: clientID, kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-04T14:25:30Z")
                let attachment = TerminalAttachment(
                    sessionID: "terminal-session", clientID: clientID, mode: .owner, attachedAt: "2026-06-04T14:25:30Z")
                let snapshot = TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment])
                return Self.terminalStateResponse(
                    try! Self.framedState(
                        text: "resumed", sessionRevision: 2, ownerEpoch: 2, emittedAt: "2026-06-04T14:25:30Z", attachmentSnapshot: snapshot))
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()

            let didTakeOver = try await waitForTerminalControlAction(.takeover, count: 1, recorder: recorder)
            XCTAssertTrue(didTakeOver, "the first post-resume state must reclaim a lease-expired owner")
            let requests = await recorder.snapshot()
            let heartbeatIndex = requests.firstIndex { request in
                guard case .terminalControl(let payload) = request.command else { return false }
                return payload.action == .heartbeat
            }
            let attachIndex = requests.firstIndex { request in
                guard case .terminalControl(let payload) = request.command else { return false }
                return payload.action == .attach
            }
            let stateIndex = requests.firstIndex { request in
                if case .state = request.command { return true }
                return false
            }
            XCTAssertNotNil(heartbeatIndex)
            XCTAssertNotNil(attachIndex)
            XCTAssertNotNil(stateIndex)
            if let heartbeatIndex, let attachIndex, let stateIndex {
                XCTAssertLessThan(heartbeatIndex, attachIndex, "an expired client must reattach after heartbeat reports it missing")
                XCTAssertLessThan(attachIndex, stateIndex, "the ownership read must follow the viewer reattach")
            }
            await waitUntil("the resumed viewer to become the owner") { model.isOwner }
            await waitUntil("the resumed owner render to be ready") { model.ownerRenderEpoch != nil && !model.isOwnershipSynchronizationPending }
            model.setInputSurfaceReady(true)
            XCTAssertTrue(model.acceptsInput, "the reclaimed terminal must return to its interactive owner state")
        }

        /// Stale-client expiry detaches a lease-expired viewer and broadcasts the attachment state before it
        /// returns, so the payload that carries the expiry is what tells the client its attachment is gone.
        /// Nothing else does: the heartbeats an attached viewer relies on are sent by the daemon's own relay,
        /// which discards the `notFound` answer.
        func testStreamStateShowingThisClientDetachedReattachesItWithoutUserAction() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:26:00Z")
            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:26:00Z")
            let expiredState = Self.runningTerminalState(
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner]),
                emittedAt: "2026-06-04T14:26:00Z")
            await model.applyLatestState(expiredState, isOutOfBand: false)

            let didAttach = try await waitForTerminalControlAction(.attach, count: 1, recorder: recorder)
            XCTAssertTrue(didAttach, "a client the daemon detached must reattach on its own")
            let attachRequests = await recorder.snapshot().compactMap { request -> SpacesDeviceTerminalControlRequest? in
                guard case .terminalControl(let payload) = request.command, payload.action == .attach else { return nil }
                return payload
            }
            XCTAssertEqual(attachRequests.count, 1)
            XCTAssertEqual(attachRequests.first?.attachmentMode, .viewer, "an expired owner must not displace the client that owns the session now")
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 0, "the reattach must not take ownership back from another client")
        }

        /// The daemon broadcasts the attachment only once the reattach lands, so payloads emitted before it
        /// keep arriving with a snapshot that predates the attachment. Reacting to each of those would send
        /// one attach per payload for as long as an output stream lasts.
        func testStaleStatesArrivingAfterAnAutomaticReattachDoNotStackMoreAttaches() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let control) = request.command, control.action == .attach, let client = control.client {
                    // The daemon carries the post-attach state on the control's own response, which is
                    // where this client reads which attachment it now holds.
                    let attached = TerminalAttachment(
                        sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attached]),
                            emittedAt: "2026-06-04T14:26:30Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:26:00Z")
            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:26:00Z")
            let detachedSnapshot = TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner])
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: detachedSnapshot, emittedAt: "2026-06-04T14:26:00Z"), isOutOfBand: false)
            let didAttach = try await waitForTerminalControlAction(.attach, count: 1, recorder: recorder)
            XCTAssertTrue(didAttach, "a client the daemon detached must reattach on its own")

            for index in 0..<3 {
                await model.applyLatestState(
                    Self.runningTerminalState(attachmentSnapshot: detachedSnapshot, emittedAt: "2026-06-04T14:26:0\(index + 1)Z"), isOutOfBand: false)
            }
            try await Task.sleep(for: .milliseconds(150))
            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(attachCount, 1, "the reattach must fire once per detachment, not once per payload")
        }

        /// The reclaim's takeover can fail on the transport before it ever reaches the daemon, and the
        /// attempt it consumed is the only one this open makes on its own. Recovery goes to the same redial
        /// a failed reattach uses, and the state its connect bootstrap reads performs the takeover again.
        func testATransientTakeoverFailureInTheReclaimRetriesOnceThroughThePacedRedial() async throws {
            let backend = ReclaimTakeoverBackend(firstTakeoverFailure: SpacesDeviceAPIClientError.requestTimedOut)
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:00Z"),
                isOutOfBand: false)

            let didRetry = await backend.waitForTakeoverCount(2)
            XCTAssertTrue(didRetry, "a takeover that never reached the daemon must be retried")
            let redialDelay = model.lastScheduledReconnectDelayForTesting
            XCTAssertNotNil(redialDelay, "the retry must be armed by the redial rather than run on its own timer")
            if let redialDelay {
                XCTAssertGreaterThan(redialDelay, .zero, "the retry must be paced by the reconnect backoff, not spun as fast as payloads arrive")
            }
            await waitUntil("the expired owner to take the session back") { model.isOwner }

            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(backend.takeoverCount(), 2, "one transient failure must produce one further takeover, not a retry loop")
            let subscribeCount = await backend.subscribeCount()
            XCTAssertEqual(subscribeCount, 1, "recovery must run through a single redial")
        }

        /// The daemon's own answer is not a transport failure: a refusal is the session saying no, and
        /// retrying it would spend redials on a decision that will not change.
        func testATakeoverTheDaemonRefusesDuringTheReclaimIsNotRetried() async throws {
            let backend = ReclaimTakeoverBackend(
                firstTakeoverFailure: SpacesDeviceAPIClientError.requestFailed("another client owns this session", code: nil))
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:00Z"),
                isOutOfBand: false)

            let didTakeOver = await backend.waitForTakeoverCount(1)
            XCTAssertTrue(didTakeOver, "the expired owner must still make its one reclaim attempt")
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(backend.takeoverCount(), 1, "a refused takeover must not be retried")
            XCTAssertNil(model.lastScheduledReconnectDelayForTesting, "a refused takeover must not arm a redial")
            let subscribeCount = await backend.subscribeCount()
            XCTAssertEqual(subscribeCount, 0, "a refused takeover must not redial")
        }

        /// The daemon publishes an attachment on the stream, so an attach whose confirming broadcast never
        /// arrived is one this client cannot show evidence of. If the outage that dropped the stream
        /// outlasts the lease the daemon has expired that attachment, and carrying the optimistic fact
        /// across the redial would leave the viewer detached with nothing able to notice: the connect would
        /// skip its attach, and the fresh snapshot's missing row would read as no loss, there being no
        /// confirmed attachment to lose.
        /// A `.state` read answered before the outage still lists an attachment the lease has since expired,
        /// so a redial that consults it skips the attach it exists to make, and nothing afterwards notices:
        /// with no confirmed attachment there is none to lose, so the fresh stream's snapshot without this
        /// client reports nothing either.
        func testARedialAttachesAgainWhenFetchedStateStillListsTheUnconfirmedAttachment() async throws {
            let tracker = AttachRequestTracker()
            let backend = StageTrackerTestBackend(transportFactory: { AttachedClientStateRequestTransport(tracker: tracker) })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the open must attach and subscribe")
            await waitUntil("the open's attach to be sent") { tracker.attachCount() == 1 }
            // The bootstrap read lands and lists this client, while the stream never broadcasts it.
            await waitUntil("the bootstrap read listing this client to apply") {
                model.attachmentSnapshot.attachments.contains { $0.clientID == model.remoteClientForTesting.id && $0.detachedAt == nil }
            }

            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)

            let didRedial = await backend.waitForSubscribeCount(2)
            XCTAssertTrue(didRedial, "a dropped stream must redial")
            await waitUntil("the redial to attach again") { tracker.attachCount() == 2 }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(tracker.attachCount(), 2, "the redial must attach exactly once more")
        }

        func testAnAttachNoSnapshotConfirmedDoesNotSurviveTheRedial() async throws {
            let tracker = AttachRequestTracker()
            let backend = StageTrackerTestBackend(transportFactory: { AttachCountingRequestTransport(tracker: tracker) })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the open must attach and subscribe")
            await waitUntil("the open's attach to be sent") { tracker.attachCount() == 1 }

            // The stream dies before the daemon ever broadcasts this client's attachment, which is the
            // only evidence the attach left anywhere this client can read.
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)

            let didRedial = await backend.waitForSubscribeCount(2)
            XCTAssertTrue(didRedial, "a dropped stream must redial")
            await waitUntil("the redial to attach again") { tracker.attachCount() == 2 }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(tracker.attachCount(), 2, "the redial must attach exactly once more")
        }

        /// A direct `.state` read is ordered against what the pipeline has already reduced, but the
        /// stream's own payloads are trusted as ordered and are never refused, so one delayed behind a read
        /// that answered first still applies after it. Arming the attachment confirmation from the read
        /// would make that older payload's pre-expiry snapshot read as a fresh loss, sending a viewer
        /// attach that can demote the owner the read just restored.
        func testAnOutOfBandReadDoesNotArmTheLossADelayedStreamPayloadWouldThenReport() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            // The state read a resume applies after re-attaching: this client is attached again, and the
            // read is out of band.
            let ownClient = TerminalClient(
                id: model.remoteClientForTesting.id, kind: .remote, identity: TerminalClientIdentity(label: "iPhone"),
                connectedAt: "2026-06-04T14:26:10Z")
            let ownAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: ownClient.id, mode: .owner, attachedAt: "2026-06-04T14:26:10Z")
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [ownClient], attachments: [ownAttachment]),
                    emittedAt: "2026-06-04T14:26:10Z"), isOutOfBand: true)

            // The stream payload the daemon emitted before the expiry, delivered after that read.
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:00Z"),
                isOutOfBand: false)

            try await Task.sleep(for: .milliseconds(200))
            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(attachCount, 0, "a snapshot older than the read that restored the attachment must not report a loss")
        }

        /// The daemon publishes the attachment only once the reattach lands, so payloads emitted before it
        /// keep arriving with a snapshot that predates it. One of those must not erase an attach the daemon
        /// acknowledged: a viewer that believed itself detached would leave without detaching, stranding
        /// the attachment on the daemon until its lease expired.
        func testAStaleSnapshotAfterAnAutomaticReattachStillLeavesTheDismissalADetachToSend() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:26:00Z")
            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:26:00Z")
            let detachedSnapshot = TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner])
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: detachedSnapshot, emittedAt: "2026-06-04T14:26:00Z"), isOutOfBand: false)
            let didAttach = try await waitForTerminalControlAction(.attach, count: 1, recorder: recorder)
            XCTAssertTrue(didAttach, "a client the daemon detached must reattach on its own")

            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: detachedSnapshot, emittedAt: "2026-06-04T14:26:01Z"), isOutOfBand: false)
            model.stop()

            let didDetach = try await waitForTerminalControlAction(.detach, count: 1, recorder: recorder)
            XCTAssertTrue(didDetach, "leaving must detach the attachment the reattach acknowledged")
            try await Task.sleep(for: .milliseconds(150))
            let detachCount = await recorder.countTerminalControlAction(.detach)
            XCTAssertEqual(detachCount, 1, "leaving must send exactly one detach")
        }

        /// A reattach can fail on the command channel alone while the subscription the viewer reads output
        /// over stays up, so nothing tears the viewer down on its own and the once-per-detachment gate is
        /// already spent. Recovery goes to `scheduleReconnect`, the model's one redial path: it drops the
        /// subscription and attaches again from the connect bootstrap, at the delay every other connect
        /// failure is paced by, instead of a retry loop at the failure site racing that pacing with its own.
        func testAReattachThatFailsOnTheCommandChannelRecoversThroughOnePacedRedial() async throws {
            let backend = LostAttachmentRedialBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:26:00Z")
            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:26:00Z")
            let detachedSnapshot = TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner])
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: detachedSnapshot, emittedAt: "2026-06-04T14:26:00Z"), isOutOfBand: false)
            let didAttach = await backend.waitForAttachCount(1)
            XCTAssertTrue(didAttach, "a client the daemon detached must start its reattach")

            for index in 0..<3 {
                await model.applyLatestState(
                    Self.runningTerminalState(attachmentSnapshot: detachedSnapshot, emittedAt: "2026-06-04T14:26:0\(index + 1)Z"), isOutOfBand: false)
            }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(backend.attachModes().count, 1, "payloads arriving while the reattach is in flight must not stack more attaches")
            XCTAssertNil(model.lastScheduledReconnectDelayForTesting, "a reattach still in flight must not have armed a redial")

            backend.releaseHeldAttach()

            let didRedial = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didRedial, "a reattach that fails on the command channel must hand recovery to the redial path")
            let redialDelay = model.lastScheduledReconnectDelayForTesting
            XCTAssertNotNil(redialDelay, "the failed reattach must arm the redial rather than abandon recovery")
            if let redialDelay {
                XCTAssertGreaterThan(redialDelay, .zero, "the retry must be paced by the reconnect backoff, not spun as fast as payloads arrive")
            }
            XCTAssertEqual(
                backend.attachModes(), [.viewer, .viewer], "the redial's connect bootstrap must attach exactly once more, still as a viewer")

            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(backend.attachModes().count, 2, "one failed reattach must produce one further attach, not a redial loop")
            let subscribeCount = await backend.subscribeCount()
            XCTAssertEqual(subscribeCount, 1, "recovery must run through a single redial")
        }

        /// A viewer that held the session when its lease expired takes it back, the same reclaim the
        /// foreground resume performs — but only because nothing else owns it by then.
        func testExpiredOwnerTakesTheOwnerlessSessionBackAfterReattaching() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let control) = request.command, control.action == .attach, let client = control.client {
                    // The daemon carries the post-attach state on the control's own response, which is
                    // where this client reads which attachment it now holds.
                    let attached = TerminalAttachment(
                        sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attached]),
                            emittedAt: "2026-06-04T14:26:30Z"))
                }
                guard case .terminalControl(let payload) = request.command, payload.action == .takeover, let clientID = payload.clientID else {
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                let client = TerminalClient(
                    id: clientID, kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-04T14:26:10Z")
                let attachment = TerminalAttachment(
                    sessionID: "terminal-session", clientID: clientID, mode: .owner, attachedAt: "2026-06-04T14:26:10Z")
                return Self.terminalStateResponse(
                    Self.runningTerminalState(
                        attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                        emittedAt: "2026-06-04T14:26:10Z"))
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:00Z"),
                isOutOfBand: false)

            let didTakeOver = try await waitForTerminalControlAction(.takeover, count: 1, recorder: recorder)
            XCTAssertTrue(didTakeOver, "an expired owner must reclaim a session nothing else owns")
            let requests = await recorder.snapshot()
            let attachIndex = requests.firstIndex { request in
                guard case .terminalControl(let payload) = request.command else { return false }
                return payload.action == .attach
            }
            let takeoverIndex = requests.firstIndex { request in
                guard case .terminalControl(let payload) = request.command else { return false }
                return payload.action == .takeover
            }
            XCTAssertNotNil(attachIndex)
            XCTAssertNotNil(takeoverIndex)
            if let attachIndex, let takeoverIndex {
                XCTAssertLessThan(attachIndex, takeoverIndex, "the daemon rejects a takeover from a client with no attachment row")
            }
            await waitUntil("the reattached viewer to become the owner again") { model.isOwner }
        }

        func testForegroundResumeConsumesLeaseExpiryStateThatArrivedWhileBackgrounded() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:00Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: model.attachmentSnapshot, emittedAt: "2026-06-04T14:25:00Z"), isOutOfBand: false)

            let backgroundTakeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(backgroundTakeoverCount, 0, "background state must wait for the scene to become active")
            model.resumeAfterBackgrounding()
            let didTakeOver = try await waitForTerminalControlAction(.takeover, count: 1, recorder: recorder)
            XCTAssertTrue(didTakeOver, "a background owner state must not hide the ownerless post-foreground result")
        }

        func testForegroundResumeDoesNotReclaimALaterLegitimateHandoffAfterOwnerConfirmation() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let stateResponse = TerminalStateResponseHolder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat { return await stateResponse.current() }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await stateResponse.set(
                Self.terminalStateResponse(Self.runningTerminalState(attachmentSnapshot: model.attachmentSnapshot, emittedAt: "2026-06-04T14:25:30Z"))
            )
            model.prepareForBackgrounding()
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: model.attachmentSnapshot, emittedAt: "2026-06-04T14:25:00Z"), isOutOfBand: false)
            model.resumeAfterBackgrounding()
            let didReadState = try await waitForTerminalControlAction(.heartbeat, count: 1, recorder: recorder)
            XCTAssertTrue(didReadState, "foreground resume must evaluate ownership after activation")
            try await Task.sleep(for: .milliseconds(100))
            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(attachCount, 0, "a heartbeat-confirmed owner must not be demoted to a viewer by reattaching")

            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: "mac-owner", mode: .owner, attachedAt: "2026-06-04T14:26:00Z")
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [], attachments: [macOwner]), emittedAt: "2026-06-04T14:26:00Z"),
                isOutOfBand: false)
            try await Task.sleep(for: .milliseconds(100))

            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 0, "an owner-confirming resume state must consume the one-shot intent before a later handoff")
        }

        /// Payloads the daemon exported before this attachment existed say nothing about it. They arrive
        /// after it all the same: the stream's backlog is delivered behind the foreground recovery that
        /// re-attached, still listing the attachment that expired and then its expiry. Judged against the
        /// new attachment they read as another loss, and the `.viewer` attach that follows can demote the
        /// owner the recovery just restored.
        func testStreamPayloadsFromBeforeTheReattachReportNoSecondLoss() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let gate = ReclaimTakeoverGate()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command else {
                    if case .state = request.command {
                        return Self.terminalStateResponse(
                            Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:35Z"))
                    }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                switch payload.action {
                case .heartbeat: return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                case .attach:
                    // The daemon answers an attach with the session's state, and the client record in that
                    // answer names the attachment's identity.
                    guard let client = payload.client else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                            emittedAt: "2026-06-04T14:26:30Z"))
                case .takeover:
                    guard let clientID = payload.clientID else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    await gate.markStarted()
                    await gate.waitForRelease()
                    let client = TerminalClient(
                        id: clientID, kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-04T14:26:40Z")
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: clientID, mode: .owner, attachedAt: "2026-06-04T14:26:40Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                            emittedAt: "2026-06-04T14:26:40Z"))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            let ownClient = TerminalClient(
                id: model.remoteClientForTesting.id, kind: .remote, identity: TerminalClientIdentity(label: "iPhone"),
                connectedAt: "2026-06-04T14:25:00Z")
            let expiredAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: ownClient.id, mode: .owner, attachedAt: "2026-06-04T14:25:00Z")
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            await gate.waitForStart()

            // The stream's backlog, delivered behind the recovery: the attachment that has since expired,
            // then the expiry itself, both exported before the reattach the daemon has just acknowledged.
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [ownClient], attachments: [expiredAttachment]),
                    emittedAt: "2026-06-04T14:26:10Z"), isOutOfBand: false)
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:20Z"),
                isOutOfBand: false)
            await gate.release()

            await waitUntil("the reclaimed viewer to become the owner again") { model.isOwner }
            try await Task.sleep(for: .milliseconds(250))
            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(attachCount, 1, "payloads exported before the reattach must not report a loss of the attachment that replaced them")
            XCTAssertTrue(model.isOwner, "the restored owner must not be demoted by the backlog its own recovery outran")
        }

        /// A takeover's acknowledgement is a command answer this model applies in band on purpose, so the
        /// carrier alone cannot tell it apart from the stream's own payloads and the submission it is
        /// applied under is what does. Arming the confirmation from it would make the session's next
        /// attachment broadcast, an expiry included, read as a loss against an attachment the stream never
        /// confirmed.
        func testATakeoverAcknowledgementDoesNotConfirmTheAttachment() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command else {
                    if case .state = request.command {
                        return Self.terminalStateResponse(
                            Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:35Z"))
                    }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                switch payload.action {
                case .heartbeat: return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                case .attach:
                    guard let client = payload.client else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                            emittedAt: "2026-06-04T14:26:30Z"))
                case .takeover:
                    guard let clientID = payload.clientID else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    let client = TerminalClient(
                        id: clientID, kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-04T14:26:40Z")
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: clientID, mode: .owner, attachedAt: "2026-06-04T14:26:40Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                            emittedAt: "2026-06-04T14:26:40Z"))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            // The resume re-attaches for the client the daemon dropped and its state read is refused, so the
            // reclaim it recorded is carried to the redial behind it, whose bootstrap read is what settles
            // it -- one more attach and the takeover that takes the ownerless session back.
            let didReclaim = try await waitForTerminalControlAction(.takeover, count: 1, recorder: recorder)
            XCTAssertTrue(didReclaim, "the recovery must settle the reclaim the dropped attachment left owed")
            await waitUntil("the reclaimed viewer to own the session again") { model.isOwner }
            try await Task.sleep(for: .milliseconds(100))

            // The session's next attachment broadcast, exported after the takeover: with the takeover's own
            // acknowledgement counted as a confirmation, this reads as a loss and sends another attach.
            // Counted against what the recovery already sent, since what this test is about is this
            // broadcast sending one more.
            let attachesBeforeBroadcast = await recorder.countTerminalControlAction(.attach)
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:50Z"),
                isOutOfBand: false)

            try await Task.sleep(for: .milliseconds(250))
            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(
                attachCount, attachesBeforeBroadcast, "the broadcast must send no attach: no stream snapshot ever confirmed an attachment to lose")
        }

        /// The daemon broadcasts the session's post-attach state before it loads the state it answers the
        /// attach with, so the confirming broadcast is stamped at or before the acknowledgement that
        /// established the attachment. Ordering the confirmation by time would therefore reject the only
        /// payload that can arm it, and the viewer would go on believing a live attachment unconfirmed:
        /// every reconnect discarding it and attaching again, and no expiry ever reported as a loss.
        func testAConfirmingBroadcastStampedBeforeItsAcknowledgementStillArmsTheConfirmation() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let attaches = AttachAcknowledgementRecorder()
            let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:26:00Z")
            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:26:00Z")
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command else {
                    if case .state = request.command {
                        return Self.terminalStateResponse(
                            Self.runningTerminalState(
                                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner]),
                                emittedAt: "2026-06-04T14:26:35Z"))
                    }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                switch payload.action {
                case .heartbeat: return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                case .attach:
                    guard let client = payload.client else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    attaches.record(client)
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
                    // Stamped after the broadcast the test publishes below, which is the order the daemon
                    // produces: it broadcasts the new snapshot, then loads the state for this answer.
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(
                                clients: [macClient, client], attachments: [macOwner, attachment]), emittedAt: "2026-06-04T14:26:40Z"))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            await waitUntil("the resume's reattach to be acknowledged") { attaches.count() == 1 }
            // The resume's follow-up read is issued after that attach is acknowledged, so its Mac owner
            // landing means the acknowledgement has been read for the attachment's identity.
            await waitUntil("the resume's state read to apply") {
                model.attachmentSnapshot.attachments.contains { $0.clientID == macClient.id && $0.mode == .owner }
            }
            guard let attached = attaches.lastClient() else { return XCTFail("the resume must have attached") }

            // The daemon's own broadcast for that attach, exported before the answer above.
            let attachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: attached.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient, attached], attachments: [macOwner, attachment]),
                    emittedAt: "2026-06-04T14:26:30Z"), isOutOfBand: false)
            // The lease expires again, and the confirmed attachment's disappearance is the loss.
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner]),
                    emittedAt: "2026-06-04T14:26:45Z"), isOutOfBand: false)

            let didReattach = try await waitForTerminalControlAction(.attach, count: 2, recorder: recorder)
            XCTAssertTrue(didReattach, "a broadcast confirming the attachment must arm the loss the next expiry reports")
            try await Task.sleep(for: .milliseconds(200))
            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(attachCount, 2, "the loss must send exactly one reattach")
        }

        /// The daemon broadcasts a new attachment to every subscriber before it answers the attach that
        /// made it, so on a subscription that was already open the payload naming the replacement can reach
        /// this client while the identity it would be judged against is still the attachment that ended.
        /// Refused and forgotten, that payload is the only one that ever names the replacement on a quiet
        /// session: the sweep that eventually takes it away then reads as nothing at all, and the viewer
        /// sits detached with its input refused until the next resume or redial.
        func testABroadcastRefusedWhileTheReattachIsUnansweredStillConfirmsItOnceItIsNamed() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let attaches = AttachAcknowledgementRecorder()
            let attachGate = ReclaimTakeoverGate()
            let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:25:00Z")
            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:25:00Z")
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command else {
                    guard case .state = request.command else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    // What the resume reads once it holds an attachment again: the Mac still owns the
                    // session, and this client is the viewer its re-attach just made.
                    var clients = [macClient]
                    var attachments = [macOwner]
                    if let attached = attaches.lastClient() {
                        clients.append(attached)
                        attachments.append(
                            TerminalAttachment(
                                sessionID: "terminal-session", clientID: attached.id, mode: .viewer, attachedAt: "2026-06-04T14:26:50Z"))
                    }
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: clients, attachments: attachments),
                            emittedAt: "2026-06-04T14:27:00Z"))
                }
                switch payload.action {
                case .heartbeat: return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                case .attach:
                    guard let client = payload.client else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    attaches.record(client)
                    // Only the re-attach the expiry sends is held, so the broadcast below arrives while the
                    // attachment it names is still unacknowledged; whatever the loss sends must run freely.
                    if attaches.count() == 1 {
                        await attachGate.markStarted()
                        await attachGate.waitForRelease()
                    }
                    // The daemon stores and echoes the `connectedAt` the client sent, so this is the
                    // identity the acknowledgement resolves -- the same one the broadcast carries.
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:26:50Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(
                                clients: [macClient, client], attachments: [macOwner, attachment]), emittedAt: "2026-06-04T14:26:55Z"))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            await attachGate.waitForStart()
            guard let attaching = attaches.lastClient() else { return XCTFail("the resume must have re-attached") }
            let readsBeforeTheAcknowledgement = await recorder.countStateRequests()

            // The daemon's own broadcast for that attach, delivered on the subscription that was already
            // open: it names the attachment being established, and nothing has named that one yet.
            let attachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: attaching.id, mode: .viewer, attachedAt: "2026-06-04T14:26:50Z")
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient, attaching], attachments: [macOwner, attachment]),
                    emittedAt: "2026-06-04T14:26:50Z"), isOutOfBand: false)
            await attachGate.release()

            // The read the recovery issues once the attach is acknowledged, which is what makes its arrival
            // observable: the identity is resolved by then.
            await waitUntilAsync("the re-attach to be acknowledged and read") { await recorder.countStateRequests() > readsBeforeTheAcknowledgement }
            try await Task.sleep(for: .milliseconds(150))

            // The lease expires on a session nothing else is saying anything about, so this sweep is the
            // last word on the attachment the broadcast named.
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner]),
                    emittedAt: "2026-06-04T14:28:00Z"), isOutOfBand: false)

            let didReattach = try await waitForTerminalControlAction(.attach, count: 2, recorder: recorder)
            XCTAssertTrue(didReattach, "a broadcast the acknowledgement behind it names must arm the loss the sweep reports")
            try await Task.sleep(for: .milliseconds(200))
            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(attachCount, 2, "the loss must send exactly one re-attach")
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 0, "and a viewer's loss must leave the device that owns the session alone")
        }

        /// A command's answer carries the session as of the moment the daemon loaded it for that command,
        /// which can be before an expiry this client has already read: the takeover's acknowledgement and
        /// the expiry broadcast reach the reducer together, and the drain applies both inside one
        /// main-actor turn with the acknowledgement last. Letting it write the attachment fact puts the
        /// attachment back up under the re-attach the expiry just scheduled, and that re-attach -- which
        /// cannot run until the drain yields the main actor -- then exits at its own guard, leaving a quiet
        /// terminal attached to nothing with its input refused until the next resume or redial.
        func testACommandAnswerLandingBehindTheExpiryDoesNotStrandTheReattach() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if let acknowledgement = Self.attachAcknowledgement(for: request) { return acknowledgement }
                if case .state = request.command {
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T15:01:00Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            // A confirmed owner attachment: the expiry below is a loss of the ownership it held.
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            // Both submitted before the main actor is given up, which is what puts them in the mailbox
            // together: the lease expiry the session broadcast, then the acknowledgement `takeOver()`
            // submits in band (stamped when the daemon loaded it, before the expiry, which is exactly the
            // ordering that makes it name an attachment the expiry has already ended).
            model.submitLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T15:00:00Z"),
                isOutOfBand: false)
            model.submitLatestState(
                Self.ownedState(clientID: model.remoteClientForTesting.id, emittedAt: "2026-06-04T14:59:00Z"), isOutOfBand: false,
                isCommandResponse: true)
            Thread.sleep(forTimeInterval: 0.2)

            let didReattach = try await waitForTerminalControlAction(.attach, count: 1, recorder: recorder)
            XCTAssertTrue(didReattach, "the loss must re-attach even when a command's answer lands behind it")
            try await Task.sleep(for: .milliseconds(250))
            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(attachCount, 1, "and it must re-attach exactly once")
            XCTAssertTrue(model.isOwner, "the ownership the acknowledgement reported is still this client's")
        }

        /// The mints that can collide are the ones no round trip separates: a recovery's re-attach and the
        /// redial behind it are consecutive requests on one command channel, so they land inside the same
        /// millisecond, and a clock that steps backwards can repeat a value outright. A stamp is only an
        /// identity if no two of them are ever equal, so every mint is ordered against the last.
        func testEveryAttachmentIdentityThisModelMintsIsDistinctAndIncreasing() async throws {
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: SpacesDeviceAPIClient(settings: settings()) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") })
            defer { model.stop() }

            // Minted back to back, which is what puts several of them inside one clock millisecond.
            let identities = (0..<50).map { _ in model.mintAttachmentConnectedAtForTesting() }

            XCTAssertEqual(Set(identities).count, identities.count, "two attaches must never be published under one identity")
            for (earlier, later) in zip(identities, identities.dropFirst()) {
                let earlierDate = try XCTUnwrap(TerminalSessionTimestamp.date(from: earlier), "an identity must stay a timestamp every reader parses")
                let laterDate = try XCTUnwrap(TerminalSessionTimestamp.date(from: later), "an identity must stay a timestamp every reader parses")
                XCTAssertGreaterThan(laterDate, earlierDate, "each attachment must be dated after the one it replaces")
            }
        }

        /// A headless daemon stores the client record as sent, so on one the attachment identity is the
        /// `connectedAt` this client mints, and its precision is what decides whether two attaches can be
        /// told apart. Attaches come in bursts -- an expiry's re-attach, the redial behind it -- well
        /// inside one second, and at whole-second precision they would share an identity: a snapshot of
        /// the attachment that ended would then pass as evidence about the one that replaced it. (The
        /// macOS daemon replaces the field with its own lease stamp, minted at the same precision for the
        /// same reason; `GhosttyEmbeddedSessionHostTests` covers that side.)
        func testTwoAttachesInsideOneSecondGetDistinctIdentities() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let attaches = AttachAcknowledgementRecorder()
            let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:25:00Z")
            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:25:00Z")
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command else {
                    if case .state = request.command {
                        return Self.terminalStateResponse(
                            Self.runningTerminalState(
                                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner]),
                                emittedAt: "2026-06-04T14:26:35Z"))
                    }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                switch payload.action {
                case .heartbeat: return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                case .attach:
                    guard let client = payload.client else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    attaches.record(client)
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(
                                clients: [macClient, client], attachments: [macOwner, attachment]), emittedAt: "2026-06-04T14:26:40Z"))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            await waitUntil("the resume's re-attach to be acknowledged") { attaches.count() == 1 }
            await waitUntil("the resume's state read to apply") {
                model.attachmentSnapshot.attachments.contains { $0.clientID == macClient.id && $0.mode == .owner }
            }
            guard let attached = attaches.lastClient() else { return XCTFail("the resume must have re-attached") }

            // Confirm that attachment from the stream, then take it away: the loss sends the second attach,
            // milliseconds after the first.
            let attachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: attached.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient, attached], attachments: [macOwner, attachment]),
                    emittedAt: "2026-06-04T14:26:30Z"), isOutOfBand: false)
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner]),
                    emittedAt: "2026-06-04T14:26:45Z"), isOutOfBand: false)
            let didReattach = try await waitForTerminalControlAction(.attach, count: 2, recorder: recorder)
            XCTAssertTrue(didReattach, "the loss must send the re-attach this test measures")

            let clients = attaches.allClients()
            XCTAssertEqual(clients.count, 2, "exactly the attach the resume sent and the one the loss sent")
            XCTAssertNotEqual(
                clients[0].connectedAt, clients[1].connectedAt, "two attaches this close together must not share an attachment identity")
            for client in clients {
                XCTAssertNotNil(
                    TerminalSessionTimestamp.date(from: client.connectedAt), "the daemon must be able to read the identity this client mints")
                XCTAssertTrue(
                    client.connectedAt.contains("."),
                    "the identity must carry sub-second precision, or two attaches inside one second would be the same attachment")
            }
        }

        /// A re-attach asking for the mode the attachment already has is a daemon-side no-op
        /// (`GhosttyEmbeddedSessionHost.attachClient` applies nothing when the mode is unchanged), so the
        /// attachment keeps the `connectedAt` it was created with and the value this client sent is never
        /// published. The identity the confirmation is judged against therefore has to be read back off the
        /// acknowledgement's own snapshot; remembering what was sent would leave a short outage's re-attach
        /// permanently unconfirmable.
        func testTheAttachmentIdentityIsReadFromTheAcknowledgementNotFromTheRequest() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let attaches = AttachAcknowledgementRecorder()
            let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:26:00Z")
            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:26:00Z")
            // The value the daemon kept from the attachment this re-attach did not replace.
            let keptConnectedAt = "2026-06-04T14:20:00Z"
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command else {
                    if case .state = request.command {
                        return Self.terminalStateResponse(
                            Self.runningTerminalState(
                                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner]),
                                emittedAt: "2026-06-04T14:26:35Z"))
                    }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                switch payload.action {
                case .heartbeat: return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                case .attach:
                    guard let client = payload.client else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    attaches.record(client)
                    let kept = TerminalClient(id: client.id, kind: client.kind, identity: client.identity, connectedAt: keptConnectedAt)
                    let attachment = TerminalAttachment(sessionID: "terminal-session", clientID: kept.id, mode: .viewer, attachedAt: keptConnectedAt)
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient, kept], attachments: [macOwner, attachment]),
                            emittedAt: "2026-06-04T14:26:20Z"))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            await waitUntil("the resume's reattach to be acknowledged") { attaches.count() == 1 }
            await waitUntil("the resume's state read to apply") {
                model.attachmentSnapshot.attachments.contains { $0.clientID == macClient.id && $0.mode == .owner }
            }
            guard let attached = attaches.lastClient() else { return XCTFail("the resume must have attached") }
            XCTAssertNotEqual(attached.connectedAt, keptConnectedAt, "the request must carry its own value for the daemon to keep or replace")

            // Every snapshot the daemon publishes for this attachment carries the value it kept.
            let kept = TerminalClient(id: attached.id, kind: attached.kind, identity: attached.identity, connectedAt: keptConnectedAt)
            let attachment = TerminalAttachment(sessionID: "terminal-session", clientID: kept.id, mode: .viewer, attachedAt: keptConnectedAt)
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient, kept], attachments: [macOwner, attachment]),
                    emittedAt: "2026-06-04T14:26:40Z"), isOutOfBand: false)
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner]),
                    emittedAt: "2026-06-04T14:26:45Z"), isOutOfBand: false)

            let didReattach = try await waitForTerminalControlAction(.attach, count: 2, recorder: recorder)
            XCTAssertTrue(didReattach, "the identity the daemon published must be the one the confirmation is judged against")
            try await Task.sleep(for: .milliseconds(200))
            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(attachCount, 2, "the loss must send exactly one reattach")
        }

        /// Ownership this model holds is held through an attachment, and a reconnect discards an attachment
        /// no snapshot ever confirmed. The attach that replaces it is a `.viewer` attach, like every attach
        /// this model sends, so the discard gives the session back — and with the one automatic takeover
        /// already spent on the takeover that won it, nothing would ask for it again: the viewer would come
        /// back from a dropped stream demoted, with only the manual Take Over action left.
        func testARedialThatDiscardsAnUnconfirmedAttachmentAsksForTheSessionAgain() async throws {
            let ownership = SessionOwnershipTracker()
            let backend = StageTrackerTestBackend(transportFactory: { OwnershipTrackingRequestTransport(ownership: ownership, takeoverGate: nil) })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the open must attach and subscribe")
            await waitUntil("the open's automatic takeover to win the session") { model.isOwner }
            XCTAssertEqual(ownership.takeoverCount(), 1, "the open takes over once")

            // The stream dies before the daemon ever broadcasts this client's attachment, so the ownership
            // won through it rests on an attachment nothing confirmed.
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)

            let didRedial = await backend.waitForSubscribeCount(2)
            XCTAssertTrue(didRedial, "a dropped stream must redial")
            await waitUntil("the redial to ask for the session again") { ownership.takeoverCount() == 2 }
            await waitUntil("the redialed viewer to own the session again") { model.isOwner }
            XCTAssertEqual(ownership.attachCount(), 2, "the redial must attach exactly once more")
        }

        /// The confirmation the stream published belongs to the attachment that has just expired, so it must
        /// not outlive it. A snapshot captured before the resume re-attached (the expiry's own broadcast, or
        /// a reconnect's) can arrive while the reclaim takeover is still in flight, and against a stale
        /// confirmation it reads as a second loss: another `.viewer` attach, sent with the one automatic
        /// takeover already spent, which demotes the owner this resume just restored.
        func testAPreExpirySnapshotArrivingDuringTheReclaimTakeoverSendsNoSecondAttach() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let gate = ReclaimTakeoverGate()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command else {
                    if case .state = request.command {
                        return Self.terminalStateResponse(
                            Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:20Z"))
                    }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                if payload.action == .heartbeat { return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound) }
                guard payload.action == .takeover, let clientID = payload.clientID else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                await gate.markStarted()
                await gate.waitForRelease()
                let client = TerminalClient(
                    id: clientID, kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-04T14:26:40Z")
                let attachment = TerminalAttachment(
                    sessionID: "terminal-session", clientID: clientID, mode: .owner, attachedAt: "2026-06-04T14:26:40Z")
                return Self.terminalStateResponse(
                    Self.runningTerminalState(
                        attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                        emittedAt: "2026-06-04T14:26:40Z"))
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            // A stream snapshot confirmed this client's attachment before the lease expired.
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            await gate.waitForStart()

            // The expiry's own broadcast, captured before the resume re-attached and delivered while the
            // reclaim takeover is still in flight.
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:00Z"),
                isOutOfBand: false)
            await gate.release()

            await waitUntil("the reclaimed viewer to become the owner again") { model.isOwner }
            try await Task.sleep(for: .milliseconds(250))
            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(attachCount, 1, "only the resume's own reattach may be sent, not a second one for an attachment already replaced")
            XCTAssertTrue(model.isOwner, "the restored owner must not be demoted by a snapshot older than its reclaim")
        }

        /// A resume that finds this client's attachment expired is the lease-expired owner's reclaim, not
        /// the ordinary foreground attempt: it takes the session back only while nothing else owns it, so a
        /// client that took over while the phone was away keeps what it took. The ordinary attempt above
        /// still preempts, which is what an open and an ordinary foreground return do.
        func testForegroundResumeOfALeaseExpiredOwnerLeavesAnotherClientsOwnershipAlone() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:25:00Z")
            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:25:00Z")
            let macOwnedState = Self.runningTerminalState(
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner]),
                emittedAt: "2026-06-04T14:26:00Z")
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                }
                if case .state = request.command { return Self.terminalStateResponse(macOwnedState) }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()

            let didReattach = try await waitForTerminalControlAction(.attach, count: 1, recorder: recorder)
            XCTAssertTrue(didReattach, "a resume whose heartbeat reports the client missing must reattach")
            try await Task.sleep(for: .milliseconds(250))
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 0, "a device whose lease expired must not take the session from the client that owns it now")
            XCTAssertFalse(model.isOwner, "the expired owner comes back as a viewer")
            XCTAssertTrue(model.showsTakeOverAction, "the user keeps the Take Over action for a session another client owns")
        }

        /// A loss the stream reports while a foreground evaluation is still waiting on its heartbeat is the
        /// same expiry that heartbeat would otherwise have discovered, and re-attaching first is exactly
        /// what makes it succeed instead. The evaluation must not read that success as an ordinary
        /// foreground return: this device was detached for its lease and another client owns the session by
        /// now, so the ordinary attempt's preemption would take a live session away from the client holding
        /// it.
        func testALossReportedBeforeTheResumeHeartbeatLeavesAnotherClientsOwnershipAlone() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let attaches = AttachAcknowledgementRecorder()
            let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:25:00Z")
            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:25:00Z")
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                switch payload.action {
                case .heartbeat:
                    // The lease this heartbeat renews is the one the reattach below already restored, so it
                    // succeeds: nothing in this answer says the attachment was ever gone.
                    let viewer = attaches.lastClient()
                    let viewerAttachment = viewer.map {
                        TerminalAttachment(sessionID: "terminal-session", clientID: $0.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
                    }
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(
                                clients: [macClient] + (viewer.map { [$0] } ?? []), attachments: [macOwner] + (viewerAttachment.map { [$0] } ?? [])),
                            emittedAt: "2026-06-04T14:26:35Z"))
                case .attach:
                    guard let client = payload.client else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    attaches.record(client)
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(
                                clients: [macClient, client], attachments: [macOwner, attachment]), emittedAt: "2026-06-04T14:26:30Z"))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            // Backgrounding arms the foreground evaluation; the expiry's own broadcast reaches the stream
            // before the app comes forward, so the reattach that answers it runs first and the evaluation
            // still owes itself its ownership decision.
            model.prepareForBackgrounding()
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner]),
                    emittedAt: "2026-06-04T14:26:20Z"), isOutOfBand: false)
            let didReattach = try await waitForTerminalControlAction(.attach, count: 1, recorder: recorder)
            XCTAssertTrue(didReattach, "the reported loss must reattach")

            model.resumeAfterBackgrounding()
            let didHeartbeat = try await waitForTerminalControlAction(.heartbeat, count: 1, recorder: recorder)
            XCTAssertTrue(didHeartbeat, "the resume must still evaluate ownership")
            try await Task.sleep(for: .milliseconds(300))
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 0, "a device whose lease expired must not take the session from the client that owns it now")
            XCTAssertFalse(model.isOwner, "the expired owner comes back as a viewer")
            XCTAssertTrue(model.showsTakeOverAction, "the user keeps the Take Over action for a session another client owns")
        }

        /// The same recovery against an ownerless session is still a reclaim: nothing else holds the
        /// session, so the resume takes it back, exactly once.
        func testALossReportedBeforeTheResumeHeartbeatStillReclaimsAnOwnerlessSession() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let attaches = AttachAcknowledgementRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                switch payload.action {
                case .heartbeat:
                    guard let viewer = attaches.lastClient() else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: viewer.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [viewer], attachments: [attachment]),
                            emittedAt: "2026-06-04T14:26:35Z"))
                case .attach:
                    guard let client = payload.client else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    attaches.record(client)
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                            emittedAt: "2026-06-04T14:26:30Z"))
                case .takeover:
                    guard let clientID = payload.clientID else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    let client = TerminalClient(
                        id: clientID, kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-04T14:26:30Z")
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: clientID, mode: .owner, attachedAt: "2026-06-04T14:26:40Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                            emittedAt: "2026-06-04T14:26:40Z"))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:20Z"),
                isOutOfBand: false)
            let didReattach = try await waitForTerminalControlAction(.attach, count: 1, recorder: recorder)
            XCTAssertTrue(didReattach, "the reported loss must reattach")

            model.resumeAfterBackgrounding()
            await waitUntil("the reclaimed viewer to own the ownerless session again") { model.isOwner }
            try await Task.sleep(for: .milliseconds(200))
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 1, "an ownerless session is reclaimed by exactly one takeover")
            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(attachCount, 1, "the reported loss must send exactly one reattach")
        }

        /// The recovery's attach and the resume's heartbeat travel the one command channel a viewer uses
        /// for both, so the heartbeat runs the moment that attach frees the channel — which can be before
        /// the recovery's own task resumes. The provenance that makes this resume a reclaim is therefore
        /// recorded where the loss is detected, not once the attach returns; read a moment too late, the
        /// evaluation decides as an ordinary foreground return and preempts the client that owns the
        /// session now.
        func testARecoveryWhoseAttachSharesTheChannelWithTheResumeHeartbeatLeavesAnotherClientsOwnershipAlone() async throws {
            let tracker = ExpiredOwnerRecoveryTracker(failsFirstAttach: false)
            let backend = StageTrackerTestBackend(transportFactory: { ExpiredOwnerRecoveryTransport(tracker: tracker) })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: ExpiredOwnerRecoveryTracker.macOwnedSnapshot, emittedAt: "2026-06-04T14:26:20Z"),
                isOutOfBand: false)
            await waitUntil("the reported loss to attach") { tracker.attachCount() == 1 }

            model.resumeAfterBackgrounding()
            await waitUntil("the resume's heartbeat to be answered") { tracker.heartbeatCount() == 1 }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(tracker.takeoverCount(), 0, "a device whose lease expired must not take the session from the client that owns it now")
            XCTAssertFalse(model.isOwner, "the expired owner comes back as a viewer")
            XCTAssertTrue(model.showsTakeOverAction, "the user keeps the Take Over action for a session another client owns")
        }

        /// A recovery whose attach fails is still this resume's recovery: the redial it hands itself to
        /// picks the attach up, and the daemon may well have applied the attach whose answer was lost, so
        /// the heartbeat behind it renews a live lease either way. Dropping the provenance on that failure
        /// would leave the evaluation reading an ordinary foreground return and preempting the owner.
        func testARecoveryWhoseAttachFailsStillLeavesAnotherClientsOwnershipAlone() async throws {
            let tracker = ExpiredOwnerRecoveryTracker(failsFirstAttach: true)
            let backend = StageTrackerTestBackend(transportFactory: { ExpiredOwnerRecoveryTransport(tracker: tracker) })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: ExpiredOwnerRecoveryTracker.macOwnedSnapshot, emittedAt: "2026-06-04T14:26:20Z"),
                isOutOfBand: false)
            await waitUntil("the reported loss to attach") { tracker.attachCount() == 1 }

            model.resumeAfterBackgrounding()
            await waitUntil("the resume's heartbeat to be answered") { tracker.heartbeatCount() == 1 }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(tracker.takeoverCount(), 0, "a recovery that failed is still a recovery: the resume must not preempt the current owner")
            XCTAssertFalse(model.isOwner, "the expired owner comes back as a viewer")
            XCTAssertTrue(model.showsTakeOverAction, "the user keeps the Take Over action for a session another client owns")
        }

        /// A takeover still in flight is ownership this client is about to hold, and the redial's viewer
        /// attach queues behind that very request on the channel they share — so it lands as a demotion of
        /// the ownership the takeover just won. With the one automatic takeover already spent on that
        /// takeover, nothing would ask again and the viewer would come back demoted from a dropped stream.
        func testARedialWhileTheBootstrapsTakeoverIsInFlightAsksForTheSessionAgain() async throws {
            let ownership = SessionOwnershipTracker()
            let gate = ReclaimTakeoverGate()
            let backend = StageTrackerTestBackend(transportFactory: { OwnershipTrackingRequestTransport(ownership: ownership, takeoverGate: gate) })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the open must attach and subscribe")
            await gate.waitForStart()

            // The stream dies with the open's takeover still sending, so the attachment it wins is one no
            // snapshot ever confirmed.
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the dropped stream to arm its redial") { model.lastScheduledReconnectDelayForTesting != nil }
            // Held until that redial has begun, which is the window this finding is about: its connect
            // decides what to do with the unconfirmed attachment while the takeover is still in flight.
            let redialDelay = model.lastScheduledReconnectDelayForTesting ?? .seconds(1)
            try await Task.sleep(for: redialDelay + .milliseconds(400))
            XCTAssertEqual(ownership.takeoverCount(), 1, "the open's takeover must still be the only one in flight")
            await gate.release()

            let didRedial = await backend.waitForSubscribeCount(2)
            XCTAssertTrue(didRedial, "a dropped stream must redial")
            await waitUntil("the redial to ask for the session again") { ownership.takeoverCount() == 2 }
            await waitUntil("the redialed viewer to own the session again") { model.isOwner }
            XCTAssertEqual(ownership.attachCount(), 2, "the redial must attach exactly once more")
        }

        /// The expiry leaves the session ownerless, and a `.state` read answered after it reports exactly
        /// that — possibly before the expiry's own broadcast reaches this client. Reading ownership off
        /// what the client believes at that moment would make the owner that just lost its attachment
        /// recover as a plain viewer, leaving a running terminal ownerless with nothing asking for it. What
        /// the recovery reclaims is the ownership the lost attachment held, which is what the stream
        /// confirmed about it.
        func testAnOwnerlessReadBeforeTheExpiryBroadcastStillReclaimsTheLostOwnership() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let control) = request.command, control.action == .attach, let client = control.client {
                    // The daemon carries the post-attach state on the control's own response, which is
                    // where this client reads which attachment it now holds.
                    let attached = TerminalAttachment(
                        sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attached]),
                            emittedAt: "2026-06-04T14:26:30Z"))
                }
                guard case .terminalControl(let payload) = request.command else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                guard payload.action == .takeover, let clientID = payload.clientID else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                let client = TerminalClient(
                    id: clientID, kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-04T14:26:30Z")
                let attachment = TerminalAttachment(
                    sessionID: "terminal-session", clientID: clientID, mode: .owner, attachedAt: "2026-06-04T14:26:40Z")
                return Self.terminalStateResponse(
                    Self.runningTerminalState(
                        attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                        emittedAt: "2026-06-04T14:26:40Z"))
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            // A read answered after the expiry: the session is ownerless, and this client is no longer
            // attached. Out of band, so it says nothing about the attachment, but it does clear `isOwner`.
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:10Z"),
                isOutOfBand: true)
            XCTAssertFalse(model.isOwner, "the read reports the session the expiry left: ownerless")

            // The expiry's own broadcast, behind it on the stream: this is the loss.
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:20Z"),
                isOutOfBand: false)

            await waitUntil("the reclaimed viewer to own the session again") { model.isOwner }
            try await Task.sleep(for: .milliseconds(250))
            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(attachCount, 1, "the loss must send exactly one reattach")
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 1, "the ownerless session must be reclaimed once")
        }

        /// A resume whose heartbeat comes back `notFound` recovers by re-attaching, and that attach can
        /// fail on the command channel like any other request. Nothing is left to read for a client the
        /// daemon does not know about, so recovery goes to the model's one redial path, the same one a
        /// snapshot-driven reattach uses when its attach fails; without it the resume ends detached, with
        /// no confirmed attachment for a later expiry snapshot to report as lost either.
        func testAResumeReattachThatFailsRecoversThroughOnePacedRedial() async throws {
            let ownership = SessionOwnershipTracker()
            let backend = StageTrackerTestBackend(transportFactory: {
                OwnershipTrackingRequestTransport(ownership: ownership, takeoverGate: nil, expiresLease: true, failingAttachIndex: 1)
            })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()

            await waitUntil("the resume's reattach to fail") { ownership.attachCount() == 1 }
            // The attach is counted where the request lands, which is a hop or two ahead of the failure
            // reaching the model, so the arming is waited for rather than read the instant the count moves.
            await waitUntil("the failed reattach to arm the redial") { model.lastScheduledReconnectDelayForTesting != nil }
            let redialDelay = model.lastScheduledReconnectDelayForTesting
            XCTAssertNotNil(redialDelay, "a resume whose reattach failed must arm the redial rather than abandon recovery")
            if let redialDelay { XCTAssertGreaterThan(redialDelay, .zero, "the retry must be paced by the reconnect backoff") }

            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the redial must reconnect the stream it never had")
            await waitUntil("the redial to attach again") { ownership.attachCount() == 2 }
            await waitUntil("the ownerless session to be reclaimed") { model.isOwner }
            XCTAssertEqual(ownership.takeoverCount(), 1, "the ownerless session must be reclaimed once")
            XCTAssertEqual(ownership.attachCount(), 2, "one failed reattach must produce one further attach, not a redial loop")
        }

        /// The recovery is unfinished while its re-attach keeps failing, and the client that took the
        /// session while this device was suspended owns it throughout. Deciding ownership on what the
        /// redial happens to read — a client that still believes it is the owner, an ordinary automatic
        /// takeover nothing has spent — would preempt that client. The reclaim the dropped attachment left
        /// owed is what decides instead, wherever the decision finally lands.
        func testAResumeReattachThatKeepsFailingNeverPreemptsTheClientThatTookTheSession() async throws {
            let tracker = ExpiredOwnerRecoveryTracker(failsFirstAttach: true)
            let backend = StageTrackerTestBackend(transportFactory: { ExpiredOwnerRecoveryTransport(tracker: tracker, expiresLease: true) })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()

            await waitUntil("the resume's reattach to fail") { tracker.attachCount() == 1 }
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the failed reattach must hand recovery to the redial")
            await waitUntil("the redial to attach again") { tracker.attachCount() == 2 }
            await waitUntil("the redial's bootstrap read to settle ownership") { model.showsTakeOverAction }
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(tracker.takeoverCount(), 0, "a device whose lease expired must not take the session from the client that owns it now")
            XCTAssertFalse(model.isOwner, "the expired owner comes back as a viewer")
            XCTAssertTrue(model.showsTakeOverAction, "the user keeps the Take Over action for a session another client owns")
        }

        /// The mirror case: nothing else owns the session, so the recovery owes it a reclaim — and the
        /// payload that reported the loss has already cleared this client's ownership, while the open's own
        /// automatic takeover was spent long before. Neither is what the redial reads: the reclaim the
        /// dropped attachment left owed survives the failed re-attach and is settled by the connect
        /// bootstrap that finally lands one.
        func testAReattachThatFailsOnAnOwnerlessSessionIsStillReclaimedAfterTheRedial() async throws {
            let ownership = SessionOwnershipTracker()
            let backend = StageTrackerTestBackend(transportFactory: {
                OwnershipTrackingRequestTransport(ownership: ownership, takeoverGate: nil, failingAttachIndex: 2)
            })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the open must attach and subscribe")
            await waitUntil("the open's automatic takeover to win the session") { model.isOwner }
            XCTAssertEqual(ownership.takeoverCount(), 1, "the open spends its one automatic takeover")

            // The daemon's broadcast for the attachment this client holds, then the expiry that takes it.
            await backend.fireFrame(ownership.state())
            await backend.fireFrame(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T15:00:00Z"))

            await waitUntil("the reported loss's reattach to fail") { ownership.attachCount() == 2 }
            let didRedial = await backend.waitForSubscribeCount(2)
            XCTAssertTrue(didRedial, "the failed reattach must hand recovery to the redial")
            await waitUntil("the redial to attach again") { ownership.attachCount() == 3 }
            await waitUntil("the ownerless session to be reclaimed") { model.isOwner }
            XCTAssertEqual(ownership.takeoverCount(), 2, "the reclaim takes the ownerless session back once")
            XCTAssertEqual(ownership.attachCount(), 3, "one failed reattach must produce one further attach, not a redial loop")
        }

        /// The expiry reaches the client twice when a foreground resume is in flight over it: the snapshot
        /// that reports it, and the heartbeat behind it answered `notFound`. The second telling knows less
        /// than the first — the confirmation the snapshot cleared is what said the attachment was the
        /// owner's, and ownership has been cleared with it — so a reclaim already owed is never lowered by
        /// it, or the recovery comes back a plain viewer of a session nothing owns.
        func testAnExpirySnapshotAheadOfTheResumeHeartbeatKeepsTheOwnersReclaim() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let gate = ReclaimTakeoverGate()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command else {
                    if case .state = request.command {
                        return Self.terminalStateResponse(
                            Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:35Z"))
                    }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                switch payload.action {
                case .heartbeat:
                    // Held until the expiry's own broadcast has been applied, which is the ordering this
                    // finding is about: this answer is the second telling of the same expiry.
                    await gate.markStarted()
                    await gate.waitForRelease()
                    return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                case .attach:
                    guard let client = payload.client else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                            emittedAt: "2026-06-04T14:26:30Z"))
                case .takeover:
                    guard let clientID = payload.clientID else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    let client = TerminalClient(
                        id: clientID, kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-04T14:26:30Z")
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: clientID, mode: .owner, attachedAt: "2026-06-04T14:26:40Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                            emittedAt: "2026-06-04T14:26:40Z"))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            await gate.waitForStart()

            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:20Z"),
                isOutOfBand: false)
            await gate.release()

            await waitUntil("the ownerless session to be reclaimed") { model.isOwner }
            try await Task.sleep(for: .milliseconds(250))
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 1, "the reclaim the expiry snapshot owed must survive the heartbeat that reports the same expiry")
        }

        /// The daemon applies a takeover when it answers it, so an acknowledged takeover is ownership this
        /// client holds whether or not the stream's own broadcast of it ever arrived — and an outage that
        /// outlasts the lease is exactly the case where it did not. The attachment the expiry then drops is
        /// an owner's, not the viewer's the last stream snapshot saw, and only reading it that way brings
        /// the ownership back rather than leaving the terminal ownerless.
        func testAnAcknowledgedTakeoverTheStreamNeverConfirmedIsStillReclaimedAfterTheExpiry() async throws {
            let ownership = SessionOwnershipTracker()
            let gate = ReclaimTakeoverGate()
            let backend = StageTrackerTestBackend(transportFactory: { OwnershipTrackingRequestTransport(ownership: ownership, takeoverGate: gate) })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the open must attach and subscribe")
            await gate.waitForStart()
            guard let attached = ownership.lastAttachedClient() else { return XCTFail("the open must have attached") }

            // The stream confirms the attachment as the viewer attachment it was made as, while the open's
            // takeover is still in flight.
            let viewerAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: attached.id, mode: .viewer, attachedAt: "2026-06-04T14:30:00Z")
            await backend.fireFrame(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [attached], attachments: [viewerAttachment]),
                    emittedAt: "2026-06-04T14:30:00Z"))
            await gate.release()
            await waitUntil("the acknowledged takeover to make this client the owner") { model.isOwner }

            // The stream drops before the broadcast that would have confirmed the takeover, and the outage
            // outlasts the lease, so the daemon drops the attachment and the ownership held through it.
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            ownership.expireAttachment()
            let didRedial = await backend.waitForSubscribeCount(2)
            XCTAssertTrue(didRedial, "a dropped stream must redial")

            // The fresh stream's first snapshot is the expiry: this client holds nothing.
            await backend.fireFrame(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:40:00Z"))

            await waitUntil("the reported loss to reattach") { ownership.attachCount() == 2 }
            await waitUntil("the ownerless session to be reclaimed") { model.isOwner }
            XCTAssertEqual(ownership.takeoverCount(), 2, "the recovery must take back the ownership the acknowledged takeover won")
            XCTAssertEqual(ownership.attachCount(), 2, "the loss must send exactly one reattach")
        }

        /// The expiry can reach this client while its own takeover is still sending: the daemon takes the
        /// ownership when it answers a takeover, and one command channel carries one round trip at a time,
        /// so the answer queues behind the loss snapshot that arrives meanwhile. The attachment the lease
        /// dropped was the one carrying the ownership the user asked for, so what it leaves owed is an
        /// owner's reclaim. Read as a viewer's, the recovery attach — which re-attaches as a viewer and so
        /// gives up the ownership the acknowledgement just won — settles with no takeover and leaves the
        /// session owned by nobody and taking no input.
        func testALossReportedWhileThisClientsTakeoverIsStillSendingIsReclaimedAsAnOwners() async throws {
            let ownership = SessionOwnershipTracker()
            let gate = ReclaimTakeoverGate()
            let backend = StageTrackerTestBackend(transportFactory: { OwnershipTrackingRequestTransport(ownership: ownership, takeoverGate: gate) })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the open must attach and subscribe")
            await gate.waitForStart()
            guard let attached = ownership.lastAttachedClient() else { return XCTFail("the open must have attached") }

            // The stream confirms the attachment as the viewer attachment the open made it as, while this
            // client's own takeover is still sending.
            let viewerAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: attached.id, mode: .viewer, attachedAt: "2026-06-04T14:30:00Z")
            await backend.fireFrame(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [attached], attachments: [viewerAttachment]),
                    emittedAt: "2026-06-04T14:30:00Z"))

            // The lease expires before the takeover is answered, so the loss reaches this client first.
            ownership.expireAttachment()
            await backend.fireFrame(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:31:00Z"))
            try await Task.sleep(for: .milliseconds(150))

            // The takeover is answered now: the daemon applied it, and the recovery attach the loss started
            // runs behind it on the same channel, re-attaching as a viewer.
            await gate.release()
            await waitUntil("the reported loss to reattach") { ownership.attachCount() == 2 }
            await waitUntil("the ownerless session to be reclaimed") { ownership.takeoverCount() == 2 }
            await waitUntil("the reclaim to make this client the owner again") { model.isOwner }
            XCTAssertEqual(ownership.attachCount(), 2, "the loss must send exactly one reattach")
        }

        /// The daemon's backlog can still name the attachment the lease dropped, and a heartbeat answered
        /// `notFound` is exactly the moment such a payload arrives: the confirmation and the identity that
        /// would have caught it are both cleared, and the re-attach that will name the replacement has not
        /// been answered yet. Admitting it re-arms the confirmation for an attachment that is over, so the
        /// expiry behind it in that backlog reads as a fresh loss and sends a second viewer attach — which
        /// lands behind the reclaim's takeover and hands the session straight back, ownerless.
        func testTheExpiredAttachmentsOwnSnapshotIsNotEvidenceWhileTheReattachIsUnanswered() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let attachGate = ReclaimTakeoverGate()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command else {
                    guard case .state = request.command else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    // What the resume reads once it has re-attached: the session the expiry left, owned by nobody.
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:27:00Z"))
                }
                switch payload.action {
                case .heartbeat: return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                case .attach:
                    guard let client = payload.client else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    // Held so the backlog below arrives while this attach is still unanswered.
                    await attachGate.markStarted()
                    await attachGate.waitForRelease()
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:26:50Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                            emittedAt: "2026-06-04T14:26:50Z"))
                case .takeover:
                    guard let clientID = payload.clientID else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    let client = TerminalClient(
                        id: clientID, kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-04T14:26:50Z")
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: clientID, mode: .owner, attachedAt: "2026-06-04T14:27:10Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                            emittedAt: "2026-06-04T14:27:10Z"))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            let expiredClient = model.remoteClientForTesting
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            await attachGate.waitForStart()

            // The daemon exported this before the expiry: it names the attachment the lease has since
            // dropped, held as this session's owner.
            let expiredAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: expiredClient.id, mode: .owner, attachedAt: "2026-06-04T14:20:00Z")
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [expiredClient], attachments: [expiredAttachment]),
                    emittedAt: "2026-06-04T14:25:00Z"), isOutOfBand: false)
            await attachGate.release()

            // The recovery's own decision, made on the state it reads once it holds an attachment again:
            // nothing owns the session the expiry left, so it is taken back. Read from the requests rather
            // than from `isOwner`, which the backlog above would answer by itself.
            await waitUntilAsync("the recovery to take the ownerless session back") { await recorder.countTerminalControlAction(.takeover) == 1 }
            // The expiry's own broadcast, behind the backlog that named the attachment it ended.
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:28:00Z"),
                isOutOfBand: false)
            try await Task.sleep(for: .milliseconds(250))

            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(attachCount, 1, "the expiry must not read as a second loss for the attachment that replaced the one it ended")
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 1, "and the recovery must make exactly one ownership decision")
        }

        /// A resume settles its cycle's ownership against the owner this client has actually seen, not
        /// against whatever its own answer happened to carry. The daemon answers with the attachment
        /// authority it has, and it can have none — `currentLiveWireAttachmentSnapshot` is nil when the
        /// cache is empty and the reseeding read failed — so the payload names no owner while saying
        /// nothing about who owns the session. Read as an ownerless session, that takes a live terminal
        /// away from the device that owns it.
        func testAResumeAnsweredWithNoAttachmentStateLeavesTheDeviceThatOwnsTheSessionAlone() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:25:00Z")
            let macOwned = TerminalSessionAttachmentSnapshot(
                clients: [macClient],
                attachments: [
                    TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:25:00Z")
                ])
            let stateWithoutAttachments = GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-06-04T14:30:00Z",
                sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "terminal-session", servicePID: 100, childPID: 200, state: .running, updatedAt: "2026-06-04T14:30:00Z"),
                attachmentSnapshot: nil, title: "terminal", workingDirectory: "/tmp/work", outputByteCount: 0)
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return Self.terminalStateResponse(stateWithoutAttachments)
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            // The lease expires while the device is away and a Mac takes the session: the snapshot that
            // reports the loss reaches this client before the resume runs, so the reclaim is owed and the
            // owner is already visible in the state this client holds.
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: macOwned, emittedAt: "2026-06-04T14:29:00Z"), isOutOfBand: false)
            model.resumeAfterBackgrounding()

            let didHeartbeat = try await waitForTerminalControlAction(.heartbeat, count: 1, recorder: recorder)
            XCTAssertTrue(didHeartbeat, "the resume must evaluate the first post-background state")
            try await Task.sleep(for: .milliseconds(250))

            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 0, "an answer that carries no attachment state must not settle the reclaim as an ownerless session")
            XCTAssertFalse(model.isOwner, "the device whose lease expired comes back a viewer of the session the Mac owns")
            XCTAssertTrue(model.showsTakeOverAction, "the user keeps the Take Over action for a session another device owns")
        }

        /// The ownership an acknowledged takeover won is held through an attachment, and a redial gives up
        /// an attachment no snapshot confirmed — so the redial gives that ownership up too, exactly as an
        /// expiry does. What it leaves owed is therefore the same reclaim, settled on the state the connect
        /// bootstrap reads under the ownerless-only rule. Handing the ordinary one-shot back instead would
        /// make the bootstrap preempt the device that took the session during the outage.
        func testARedialThatDiscardsAnUnconfirmedTakeoverLeavesTheDeviceThatTookTheSessionAlone() async throws {
            let ownership = SessionOwnershipTracker()
            let backend = StageTrackerTestBackend(transportFactory: { OwnershipTrackingRequestTransport(ownership: ownership, takeoverGate: nil) })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the open must attach and subscribe")
            await waitUntil("the open's automatic takeover to win the session") { model.isOwner }
            XCTAssertEqual(ownership.takeoverCount(), 1, "the open spends its one automatic takeover")

            // No snapshot ever confirmed the attachment that ownership is held through: the stream drops,
            // the outage outlasts the lease, and another device takes the session while this one is away.
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            ownership.expireAttachment()
            ownership.handOverToOtherClient()
            let didRedial = await backend.waitForSubscribeCount(2)
            XCTAssertTrue(didRedial, "a dropped stream must redial")

            await waitUntil("the redial to attach again") { ownership.attachCount() == 2 }
            await waitUntil("the bootstrap to settle ownership") { model.showsTakeOverAction }
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(
                ownership.takeoverCount(), 1, "a device whose attachment no snapshot confirmed must not preempt the client that owns the session now")
            XCTAssertFalse(model.isOwner, "it comes back a viewer of the session the other device owns")
            XCTAssertTrue(model.showsTakeOverAction, "the user keeps the Take Over action")
        }

        /// A resume that learns its attachment is gone owes the session an ownership decision, and it is
        /// the only thing allowed to make it while the evaluation is pending. So a cycle that ends with no
        /// state read at all -- the re-attach worked, the state read behind it did not -- must not simply
        /// return: nothing else settles a reclaim on an idle session, since settling one takes a payload
        /// and an ownerless terminal nobody is typing at produces none, and the owner would stay a viewer
        /// of a session nothing owns until the next foreground return.
        func testAResumeWhoseStateReadFailsStillSettlesItsReclaimThroughTheRedial() async throws {
            let ownership = SessionOwnershipTracker()
            let backend = StageTrackerTestBackend(transportFactory: {
                OwnershipTrackingRequestTransport(ownership: ownership, takeoverGate: nil, expiresLease: true)
            })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the open must attach and subscribe")
            await waitUntil("the open's automatic takeover to win the session") { model.isOwner }
            // The stream publishes the owner attachment the takeover won, so the loss below is an owner's.
            await backend.fireFrame(ownership.state())

            // The lease expires while the device is away, which the resume's heartbeat is told outright.
            model.prepareForBackgrounding()
            ownership.expireAttachment()
            ownership.failNextStateRead()
            model.resumeAfterBackgrounding()

            // The re-attach lands, the state read behind it does not, and the redial that follows is what
            // carries this cycle's unsettled reclaim to a state that can settle it.
            await waitUntil("the resume to re-attach") { ownership.attachCount() == 2 }
            let didRedial = await backend.waitForSubscribeCount(2)
            XCTAssertTrue(didRedial, "an evaluation that read nothing must hand its unsettled reclaim to the redial")
            await waitUntil("the redial's bootstrap read to reclaim the ownerless session") { ownership.takeoverCount() == 2 }
            await waitUntil("the reclaim to make this client the owner again") { model.isOwner }
        }

        /// A reclaim is settled by whichever path gets a state to settle it on -- the snapshot-driven
        /// recovery, the foreground resume, or the connect bootstrap -- and every one of them settles it by
        /// starting the same takeover. That takeover can fail the way any other request does, and a
        /// transient failure never reached the daemon: the session is still ownerless and the reclaim still
        /// owed. So the retry belongs to the takeover rather than to the path that started it, or a resume
        /// comes back a viewer of a session nothing owns, with its input refused, until the user takes it
        /// over by hand.
        func testAResumeWhoseReclaimTakeoverTimesOutRetriesItThroughTheRedial() async throws {
            let ownership = SessionOwnershipTracker()
            let backend = StageTrackerTestBackend(transportFactory: {
                OwnershipTrackingRequestTransport(ownership: ownership, takeoverGate: nil, expiresLease: true, failingTakeoverIndex: 1)
            })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()

            // The heartbeat is answered `notFound`, the re-attach behind it lands, and the state read
            // behind that finds the session ownerless -- so the resume settles its reclaim by taking the
            // session back, and that takeover times out on its way to the daemon.
            await waitUntil("the resume to re-attach after its heartbeat was refused") { ownership.attachCount() == 1 }
            await waitUntil("the resume's reclaim to send its takeover") { ownership.takeoverAttemptCount() == 1 }
            let didRedial = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didRedial, "a reclaim takeover that never reached the daemon must hand the retry to the redial")
            await waitUntil("the redial to attach again") { ownership.attachCount() == 2 }
            await waitUntil("the redial's bootstrap read to reclaim the ownerless session") { model.isOwner }
            XCTAssertEqual(ownership.takeoverAttemptCount(), 2, "the reclaim must be retried exactly once, not abandoned and not looped")
            XCTAssertEqual(ownership.takeoverCount(), 1, "only the retry reaches the daemon")
            XCTAssertEqual(ownership.attachCount(), 2, "one redial, not a redial loop")
        }

        /// A control carries the session as it stands after the daemon applied it, and a re-attach sent to
        /// recover a dropped attachment is answered in a window another device can take the session in.
        /// That acknowledgement is the newest thing this client knows about ownership, so the reclaim
        /// behind it is settled on it; settled on the state the loss left -- an ownerless session, since
        /// the expiry cleared the ownership with the attachment -- the recovery sends its unconditional
        /// takeover straight through the device that owns the session now.
        func testAReattachAcknowledgedAfterAnotherDeviceTookTheSessionLeavesThatDeviceAlone() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:26:30Z")
            let macOwnership = TerminalAttachment(
                sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:26:30Z")
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command, payload.action == .attach, let client = payload.client else {
                    guard case .state = request.command else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwnership]),
                            emittedAt: "2026-06-04T14:26:45Z"))
                }
                // The Mac took the session over while this attach was in flight, so the state the daemon
                // carries back on the acknowledgement already names that device the owner.
                let attachment = TerminalAttachment(
                    sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:26:40Z")
                return Self.terminalStateResponse(
                    Self.runningTerminalState(
                        attachmentSnapshot: TerminalSessionAttachmentSnapshot(
                            clients: [macClient, client], attachments: [macOwnership, attachment]), emittedAt: "2026-06-04T14:26:40Z"))
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            // The expiry's broadcast: the owner attachment this client held is gone, and the ownership it
            // held is gone with it, which is the state the recovery would otherwise decide on.
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:20Z"),
                isOutOfBand: false)

            await waitUntilAsync("the loss to re-attach") { await recorder.countTerminalControlAction(.attach) == 1 }
            await waitUntil("the reclaim to settle against the device that owns the session") { model.showsTakeOverAction }
            try await Task.sleep(for: .milliseconds(250))
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 0, "a recovery must never displace the device that took the session while its re-attach was in flight")
            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(attachCount, 1, "the loss must send exactly one re-attach")
            XCTAssertFalse(model.isOwner, "the expired owner comes back a viewer of the session the Mac owns")
            XCTAssertTrue(model.showsTakeOverAction, "the user keeps the Take Over action to decide for themselves")
        }

        /// An acknowledgement that names no attachment leaves this client unable to recognize its own
        /// attachment in any snapshot, and nothing on the stream can answer that: a subscription opened
        /// before the attach keeps delivering payloads that may predate it. The `.state` read on the same
        /// command channel can, since the daemon orders it after the attach and it carries the snapshot
        /// that names this client's `connectedAt`. Unresolved, the confirmation never arms and the next
        /// expiry is read as nothing at all, leaving the viewer attached to nothing with its input refused.
        func testAnAcknowledgementWithoutStateIsNamedByTheReadBehindIt() async throws {
            let ownership = SessionOwnershipTracker()
            let backend = StageTrackerTestBackend(transportFactory: {
                OwnershipTrackingRequestTransport(ownership: ownership, takeoverGate: nil, unnamedAttachAcknowledgement: .empty)
            })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the open must attach and subscribe")
            await waitUntil("the open's automatic takeover to win the session") { model.isOwner }

            // The daemon's own broadcast for the attachment this client holds. It names the attachment by
            // the `connectedAt` only the read behind the acknowledgement could have told this model about.
            await backend.fireFrame(ownership.state())
            // The sweep takes that attachment, and this payload is the daemon saying so.
            ownership.expireAttachment()
            await backend.fireFrame(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T15:00:00Z"))

            await waitUntil("the expiry to be read as the loss it is") { ownership.attachCount() == 2 }
            await waitUntil("the reclaim to make this client the owner again") { model.isOwner }
            XCTAssertEqual(ownership.attachCount(), 2, "the loss must send exactly one re-attach")
        }

        /// The daemon can also answer an attach with the session and no attachment snapshot at all, which
        /// its own attachment cache is allowed to leave it unable to report. That answer names the
        /// attachment no better than an empty one does, so what decides the naming read is the unnamed
        /// identity rather than whether an answer arrived: read the other way, this client holds an
        /// attachment it can never recognize, and the expiry that ends it reads as nothing at all.
        func testAnAcknowledgementCarryingNoAttachmentSnapshotIsNamedByTheReadBehindIt() async throws {
            let ownership = SessionOwnershipTracker()
            let backend = StageTrackerTestBackend(transportFactory: {
                OwnershipTrackingRequestTransport(
                    ownership: ownership, takeoverGate: nil, unnamedAttachAcknowledgement: .sessionWithoutAttachmentSnapshot)
            })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the open must attach and subscribe")
            await waitUntil("the open's automatic takeover to win the session") { model.isOwner }

            // The daemon's own broadcast for the attachment this client holds, named by the `connectedAt`
            // only the read behind that acknowledgement could have told this model about.
            await backend.fireFrame(ownership.state())
            // The sweep takes that attachment, and this payload is the daemon saying so.
            ownership.expireAttachment()
            await backend.fireFrame(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T15:00:00Z"))

            await waitUntil("the expiry to be read as the loss it is") { ownership.attachCount() == 2 }
            await waitUntil("the reclaim to make this client the owner again") { model.isOwner }
            XCTAssertEqual(ownership.attachCount(), 2, "the loss must send exactly one re-attach")
        }

        /// The read that names the attachment is a request like any other and can fail. Nothing local can
        /// finish the attach then, so recovery goes to the model's one redial path, whose bootstrap attaches
        /// again -- and that acknowledgement is the ordinary one, carrying the state that names it.
        func testAnAcknowledgementWhoseNamingReadFailsRecoversThroughOnePacedRedial() async throws {
            let ownership = SessionOwnershipTracker()
            let backend = StageTrackerTestBackend(transportFactory: {
                OwnershipTrackingRequestTransport(ownership: ownership, takeoverGate: nil, unnamedAttachAcknowledgement: .empty)
            })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            // The first `.state` read of the run is the one the acknowledgement above owes its name to.
            ownership.failNextStateRead()
            model.start()

            await waitUntil("the open's attach to be acknowledged without a name") { ownership.attachCount() == 1 }
            await waitUntil("the failed read to arm the redial") { model.lastScheduledReconnectDelayForTesting != nil }
            if let redialDelay = model.lastScheduledReconnectDelayForTesting {
                XCTAssertGreaterThan(redialDelay, .zero, "the retry must be paced by the reconnect backoff")
            }
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the redial must open the subscription the failed attach never reached")
            await waitUntil("the redial to attach again") { ownership.attachCount() == 2 }
            await waitUntil("the bootstrap to reclaim the ownerless session") { model.isOwner }
            XCTAssertEqual(ownership.attachCount(), 2, "one failed read must produce one further attach, not a redial loop")
        }

        /// An attach the daemon acknowledges without a session state is an ordinary answer, not a failure:
        /// it loads the post-control state with `try?`. The attachment is real, so the acknowledgement is
        /// not the same as never having attached -- read that way, a snapshot naming this client by id
        /// alone is admitted under the pre-first-attach rule, and the daemon's pre-expiry backlog is
        /// exactly such a snapshot. Admitting it re-arms the confirmation for the attachment that just
        /// ended, so the expiry behind it reads as a second loss and sends a second viewer attach, which
        /// lands behind the reclaim's takeover and hands the session back, ownerless. The window is the
        /// read that names the attachment, held open here, and it is silent about this client throughout.
        func testAnAcknowledgementThatNamesNothingStillRefusesTheEndedAttachmentsOwnSnapshot() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let namingReadGate = ReclaimTakeoverGate()
            let attaches = AttachAcknowledgementRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command else {
                    guard case .state = request.command else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    // The read that names the attachment the acknowledgement left unnamed, held so the
                    // backlog below arrives while this client still cannot recognize its own attachment.
                    // It reports the session the expiry left: this client attached again, owned by nobody.
                    await namingReadGate.markStarted()
                    await namingReadGate.waitForRelease()
                    guard let attached = attaches.lastClient() else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    // The attachment the attach above made, under the `connectedAt` the daemon stored as
                    // sent -- the name the acknowledgement withheld.
                    let named = TerminalClient(id: attached.id, kind: attached.kind, identity: attached.identity, connectedAt: "2026-06-04T14:26:35Z")
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: named.id, mode: .viewer, attachedAt: "2026-06-04T14:26:35Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [named], attachments: [attachment]),
                            emittedAt: "2026-06-04T14:26:35Z"))
                }
                switch payload.action {
                case .heartbeat: return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                // The acknowledgement the daemon gives when its own load of the post-control state came
                // back empty: the attach landed, and nothing in the answer names the attachment it made.
                case .attach:
                    if let client = payload.client { attaches.record(client) }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                case .takeover:
                    guard let clientID = payload.clientID else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    let client = TerminalClient(
                        id: clientID, kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-04T14:26:35Z")
                    let attachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: clientID, mode: .owner, attachedAt: "2026-06-04T14:26:40Z")
                    return Self.terminalStateResponse(
                        Self.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                            emittedAt: "2026-06-04T14:26:40Z"))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            let expiredClient = model.remoteClientForTesting
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()

            // The heartbeat is refused and the re-attach is acknowledged with nothing, so the attachment is
            // real and unnamed while the read that will name it is still in flight.
            await namingReadGate.waitForStart()

            // The daemon's own export for the attachment the lease dropped, delivered late: it names this
            // client, and the client id is all it has in common with the attachment that replaced it.
            let endedAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: expiredClient.id, mode: .owner, attachedAt: "2026-06-04T14:20:00Z")
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [expiredClient], attachments: [endedAttachment]),
                    emittedAt: "2026-06-04T14:26:30Z"), isOutOfBand: false)
            await namingReadGate.release()

            await waitUntilAsync("the recovery to take the ownerless session back") { await recorder.countTerminalControlAction(.takeover) == 1 }
            // The expiry's own broadcast, behind the backlog that named the attachment it ended.
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:27:00Z"),
                isOutOfBand: false)
            try await Task.sleep(for: .milliseconds(250))

            let attachCount = await recorder.countTerminalControlAction(.attach)
            XCTAssertEqual(
                attachCount, 1, "an attachment the daemon acknowledged without naming must not be re-armed by a snapshot matching the id alone")
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 1, "and the recovery must make exactly one ownership decision")
        }

        /// The daemon applies nothing when a re-attach asks for the mode the attachment already has, so a
        /// redial made while the lease is already overdue renews nothing and the stale-client sweep can
        /// still take the attachment away between the acknowledgement and the subscription's initial state.
        /// That initial state is the one payload a snapshot predating the attach cannot be — the daemon
        /// builds it on the engine actor that applied the attach — so its silence about this client is the
        /// loss itself, confirmation or no confirmation. Read any other way, the client stays attached to
        /// nothing with its input refused.
        func testASweepInsideTheRedialsAttachGapIsReadAsALossFromTheSubscriptionsFirstPayload() async throws {
            let ownership = SessionOwnershipTracker()
            let backend = StageTrackerTestBackend(transportFactory: { OwnershipTrackingRequestTransport(ownership: ownership, takeoverGate: nil) })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the open must attach and subscribe")
            await waitUntil("the open's automatic takeover to win the session") { model.isOwner }

            // Nothing on the stream ever confirmed this attachment, so the redial gives it up and attaches
            // again — the re-attach the daemon answers without touching the lease it is racing.
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            let didRedial = await backend.waitForSubscribeCount(2)
            XCTAssertTrue(didRedial, "a dropped stream must redial")
            await waitUntil("the redial to attach again") { ownership.attachCount() == 2 }
            await waitUntil("the redial's bootstrap read to settle the reclaim") { ownership.takeoverCount() == 2 }

            // The sweep reaches the overdue lease inside the gap between that acknowledgement and the new
            // subscription's initial state, which therefore carries no row for this client.
            ownership.expireAttachment()
            await backend.fireFrame(ownership.state())

            await waitUntil("the initial state's silence to be read as the loss it is") { ownership.attachCount() == 3 }
            await waitUntil("the reclaim to make this client the owner again") { model.isOwner }
            XCTAssertEqual(ownership.takeoverCount(), 3, "the ownership the dropped attachment held is taken back once")
        }

        /// That initial state is not guaranteed an apply of its own: the pipeline hands the main actor a
        /// whole queued segment at once, and a newer output carrying a full frame absorbs whatever is still
        /// pending ahead of it, so the session's next output can arrive before the main actor has applied
        /// the subscription's first payload and the two land as one. The surviving apply still has to be
        /// read as the first payload -- its own snapshot is the newer one and says the same thing -- or the
        /// sweep goes unreported exactly when the session is busy enough to produce a frame.
        func testAFirstPayloadCollapsedIntoTheOutputBehindItIsStillReadAsTheLoss() async throws {
            let ownership = SessionOwnershipTracker()
            let backend = StageTrackerTestBackend(transportFactory: { OwnershipTrackingRequestTransport(ownership: ownership, takeoverGate: nil) })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the open must attach and subscribe")
            await waitUntil("the open's automatic takeover to win the session") { model.isOwner }

            // The same overdue-lease redial as above: the re-attach renews nothing, and the sweep lands in
            // the gap between its acknowledgement and the new subscription's initial state.
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            let didRedial = await backend.waitForSubscribeCount(2)
            XCTAssertTrue(didRedial, "a dropped stream must redial")
            await waitUntil("the redial to attach again") { ownership.attachCount() == 2 }
            await waitUntil("the redial's bootstrap read to settle the reclaim") { ownership.takeoverCount() == 2 }
            // Waited for so the takeover's own answer is applied before the payloads below are submitted:
            // it is stamped when the daemon builds it, and a test payload stamped ahead of it would be
            // refused as stale metadata rather than read at all.
            await waitUntil("the reclaim's takeover to be applied") { model.isOwner }
            ownership.expireAttachment()

            // Both payloads are submitted without giving the main actor up in between, and it is then held
            // long enough for the reduce loop to queue both: the apply that follows is the one the full
            // frame collapsed the initial payload into. Both are stamped past everything this daemon
            // emits, so what they report is read rather than refused for being older than the last apply.
            model.submitLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:59:00Z"),
                isOutOfBand: false, isFirstSubscriptionPayload: true)
            model.submitLatestState(
                try Self.framedState(
                    text: "busy", sessionRevision: 5, ownerEpoch: 1, emittedAt: "2026-06-04T15:00:00Z",
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot()), isOutOfBand: false)
            Thread.sleep(forTimeInterval: 0.2)

            await waitUntil("the collapsed-into apply to be read as the loss it carries") { ownership.attachCount() == 3 }
            await waitUntil("the reclaim to make this client the owner again") { model.isOwner }
            XCTAssertEqual(ownership.takeoverCount(), 3, "the ownership the dropped attachment held is taken back once")
        }

        /// The payload that reports a loss clears the attachment fact with it, so the reclaim it records
        /// cannot be settled until the re-attach behind it lands -- and the ordinary automatic takeover
        /// runs off that same payload. A session still starting when this viewer opened it leaves the
        /// open's one takeover unspent for exactly that moment, so the ordinary attempt would send it for a
        /// client the daemon holds no attachment row for: refused outright, or landing behind the re-attach
        /// and taking the session from the device that owns it, which a device recovering from a dropped
        /// attachment may never do. The reclaim owns the decision from the moment it is recorded, settled
        /// or not.
        func testALossBeforeTheOpensTakeoverIsSpentNeverPreemptsTheOwnerWhileTheReattachIsInFlight() async throws {
            let tracker = SweptViewerTracker()
            let reattachGate = ReclaimTakeoverGate()
            let backend = StageTrackerTestBackend(transportFactory: { SweptViewerRequestTransport(tracker: tracker, reattachGate: reattachGate) })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            model.start()
            let didSubscribe = await backend.waitForSubscribeCount(1)
            XCTAssertTrue(didSubscribe, "the open must attach and subscribe")
            await waitUntil("the open's attach to be acknowledged") { tracker.attachCount() == 1 }

            // The subscription's initial state: the session is running now, the Mac owns it, and the sweep
            // has already taken this client's row -- the loss, on the first payload that could report one.
            await backend.fireFrame(SweptViewerTracker.state(client: nil, state: .running, emittedAt: "2026-06-04T14:26:00Z"))

            await reattachGate.waitForStart()
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(
                tracker.takeoverCount(), 0, "no takeover may be sent for a client whose attachment is gone and whose re-attach is still in flight")
            XCTAssertFalse(model.isOwner, "the session belongs to the Mac throughout")

            await reattachGate.release()
            await waitUntil("the re-attach to land and the reclaim to settle") { model.showsTakeOverAction }
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(tracker.takeoverCount(), 0, "a viewer's reclaim comes back a viewer of the session the Mac owns")
            XCTAssertEqual(tracker.attachCount(), 2, "the loss must send exactly one re-attach")
            XCTAssertFalse(model.isOwner, "the device that owns the session keeps it")
            XCTAssertTrue(model.showsTakeOverAction, "the user keeps the Take Over action to decide for themselves")
        }

        func testForegroundResumePreemptsAnotherActiveOwnerOnce() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:25:00Z")
            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:25:00Z")
            let macOwnedState = Self.runningTerminalState(
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner]),
                emittedAt: "2026-06-04T14:25:00Z")
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return Self.terminalStateResponse(macOwnedState)
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            let didReadState = try await waitForTerminalControlAction(.heartbeat, count: 1, recorder: recorder)
            XCTAssertTrue(didReadState, "foreground resume must evaluate the first post-background state")
            try await Task.sleep(for: .milliseconds(100))

            let didTakeOver = try await waitForTerminalControlAction(.takeover, count: 1, recorder: recorder)
            XCTAssertTrue(didTakeOver, "foreground resume must use the existing automatic takeover path for another active owner")
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:00Z"),
                isOutOfBand: false)
            try await Task.sleep(for: .milliseconds(100))
            let laterTakeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(laterTakeoverCount, 1, "the post-foreground result must allow only one automatic takeover")
        }

        func testForegroundResumeDoesNotLeaveIntentArmedWhenItsStateReadFails() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return SpacesDeviceAPIResponse(ok: false, message: "state unavailable")
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            let didReadState = try await waitForTerminalControlAction(.heartbeat, count: 1, recorder: recorder)
            XCTAssertTrue(didReadState, "foreground resume must perform one bounded ownership evaluation")
            try await Task.sleep(for: .milliseconds(100))

            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: "mac-owner", mode: .owner, attachedAt: "2026-06-04T14:26:00Z")
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [], attachments: [macOwner]), emittedAt: "2026-06-04T14:26:00Z"),
                isOutOfBand: false)
            try await Task.sleep(for: .milliseconds(100))

            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 0, "a failed resume read must not leave automatic takeover armed for a later handoff")
        }

        /// The whole point of #677: a screen that did not change while the app was suspended is confirmed
        /// against the device in one request and no frame bytes. The heartbeat quotes the frame this
        /// viewer displays, the daemon answers it with metadata only, and the screen is left exactly as it
        /// was, while still settling the one bounded foreground ownership evaluation.
        func testForegroundResumeConfirmsAnUnchangedScreenInOneRequestWithNoFrame() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let ownerSnapshotHolder = AttachmentSnapshotHolder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return Self.terminalStateResponse(
                        Self.framelessState(attachmentSnapshot: await ownerSnapshotHolder.current(), emittedAt: "2026-06-04T14:26:00Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await ownerSnapshotHolder.set(model.attachmentSnapshot)
            await model.applyLatestState(
                try Self.framedState(
                    text: "held", sessionRevision: 5, ownerEpoch: 1, emittedAt: "2026-06-04T14:25:00Z", attachmentSnapshot: model.attachmentSnapshot),
                isOutOfBand: false)
            XCTAssertEqual(model.latestState?.renderText, "held")

            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            let didHeartbeat = try await waitForTerminalControlAction(.heartbeat, count: 1, recorder: recorder)
            XCTAssertTrue(didHeartbeat, "the resume must send its state-carrying heartbeat")
            try await Task.sleep(for: .milliseconds(100))

            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.count, 1, "an unchanged screen costs exactly one round trip")
            guard case .terminalControl(let heartbeatPayload) = requests[0].command else {
                return XCTFail("the resume's only request must be the heartbeat")
            }
            XCTAssertEqual(heartbeatPayload.action, .heartbeat)
            XCTAssertEqual(
                heartbeatPayload.heldFrameIdentity, TerminalHeldFrameIdentity(ownerEpoch: 1, sessionRevision: 5),
                "the heartbeat quotes the frame this viewer displays, which is what lets the daemon omit it")
            XCTAssertEqual(model.latestState?.renderText, "held", "a frameless confirmation leaves the screen exactly as it was")
            XCTAssertTrue(model.isOwner)

            // The evaluation settled on the confirmation, so a later legitimate handoff is not reclaimed.
            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: "mac-owner", mode: .owner, attachedAt: "2026-06-04T14:27:00Z")
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [], attachments: [macOwner]), emittedAt: "2026-06-04T14:27:00Z"),
                isOutOfBand: false)
            try await Task.sleep(for: .milliseconds(100))
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 0, "the confirmed resume consumed its one-shot ownership intent")
        }

        /// The other half of the same round trip: a screen that DID change while the app was suspended
        /// comes back on the heartbeat's own response, and paints without a second request.
        func testForegroundResumeAppliesAChangedScreenFromItsHeartbeatResponse() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let ownerSnapshotHolder = AttachmentSnapshotHolder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .heartbeat {
                    return Self.terminalStateResponse(
                        try! Self.framedState(
                            text: "moved", sessionRevision: 6, ownerEpoch: 1, emittedAt: "2026-06-04T14:26:00Z",
                            attachmentSnapshot: await ownerSnapshotHolder.current()))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await ownerSnapshotHolder.set(model.attachmentSnapshot)
            await model.applyLatestState(
                try Self.framedState(
                    text: "held", sessionRevision: 5, ownerEpoch: 1, emittedAt: "2026-06-04T14:25:00Z", attachmentSnapshot: model.attachmentSnapshot),
                isOutOfBand: false)

            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            await waitUntil("the changed screen to paint") { model.latestState?.renderText == "moved" }

            let stateRequestCount = await recorder.countStateRequests()
            XCTAssertEqual(stateRequestCount, 0, "the changed screen rides the heartbeat's response, not a second read")
        }

        func testOwnerlessTerminalSaysThatNobodyOwnsIt() async {
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in })
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:25:00Z"),
                isOutOfBand: false)

            XCTAssertEqual(model.visibleText, "This terminal has no active owner.\nTake over to start typing.")
        }

        func testOwnerWithNoClientIdentityStillReadsAsAnotherClient() async {
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in })
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            let unknownOwner = TerminalAttachment(
                sessionID: "terminal-session", clientID: "unknown-owner", mode: .owner, attachedAt: "2026-06-04T14:25:00Z")
            await model.applyLatestState(
                Self.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [], attachments: [unknownOwner]), emittedAt: "2026-06-04T14:25:00Z"
                ), isOutOfBand: false)

            XCTAssertEqual(model.visibleText, "Live terminal rendering is limited to the active owner.\nCurrent owner: another client")
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
            XCTAssertEqual(payload.client?.kind, .remote)
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
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-04T14:23:30Z",
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

        func testOpenTerminalLinkShowsSafariLinkForNonMediaExternalURL() async throws {
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

            let safariLink = try XCTUnwrap(model.safariLink)
            XCTAssertEqual(safariLink.url, URL(string: "https://example.com/docs")!)
            XCTAssertNil(model.linkPreview, "a plain web page must not also set the isolated-preview state")
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
            XCTAssertEqual(model.safariLink?.url, URL(string: "https://example.com/docs")!)
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

        func testOpenTerminalLinkFailureSetsErrorMessage() async {
            let settings = settings()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                switch request.commandName {
                case "resolveTerminalLink": return SpacesDeviceAPIResponse(ok: false, message: "Terminal link file is not a readable regular file.")
                default: return SpacesDeviceAPIResponse(ok: false, message: "unexpected command")
                }
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)

            await model.openTerminalLink("broken-link")

            XCTAssertNil(model.linkPreview)
            XCTAssertEqual(model.linkPreviewErrorMessage, "Terminal link file is not a readable regular file.")
            XCTAssertFalse(model.isPreparingLinkPreview)
        }

        func testDismissLinkBannersClearsErrorAndNotice() {
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in })
            model.linkPreviewErrorMessage = "Terminal link file is not a readable regular file."
            model.linkNotice = "This address runs on the session's host machine and isn't reachable from this device yet."

            model.dismissLinkBanners()

            XCTAssertNil(model.linkPreviewErrorMessage)
            XCTAssertNil(model.linkNotice)
        }

        func testDismissLinkBannersLeavesPreviewAndPreparingStateIntact() {
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in })
            let preview = TerminalLinkPreview(
                id: "link-1", title: "image.png", kind: .image, content: .quickLook(URL(fileURLWithPath: "/tmp/image.png")))
            model.linkPreview = preview
            model.isPreparingLinkPreview = true
            model.linkPreviewErrorMessage = "Terminal link file is not a readable regular file."
            model.linkNotice = "This address runs on the session's host machine and isn't reachable from this device yet."

            model.dismissLinkBanners()

            XCTAssertEqual(model.linkPreview, preview)
            XCTAssertTrue(model.isPreparingLinkPreview)
            XCTAssertNil(model.linkPreviewErrorMessage)
            XCTAssertNil(model.linkNotice)
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

        /// Reduction runs off the main actor, so a payload is not installed by the time the call that
        /// submitted it returns. The routes that read this model's own state immediately afterwards
        /// — takeover asking whether it became the owner, the connect bootstrap asking whether it is
        /// still connecting — have to wait for their payload, and everything the stream submitted before
        /// it has to be applied first: reduction is one chain across both routes.
        func testAnAwaitedApplyLandsAfterEverythingSubmittedBeforeIt() async {
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in })

            model.submitLatestState(Self.outputState(title: "first", emittedAt: "2026-06-04T14:23:31Z"), isOutOfBand: false)
            model.submitLatestState(Self.outputState(title: "second", emittedAt: "2026-06-04T14:23:32Z"), isOutOfBand: false)
            await model.applyLatestState(Self.outputState(title: "third", emittedAt: "2026-06-04T14:23:33Z"), isOutOfBand: false)

            XCTAssertEqual(model.latestState?.title, "third")
            XCTAssertEqual(model.latestState?.emittedAt, "2026-06-04T14:23:33Z")
            XCTAssertEqual(model.title, "third")
        }

        /// The apply mailbox collapses a run of screen-content payloads to its newest member, so what
        /// reaches the model is the newest state plus what the payloads it replaced asked for. The
        /// inherited resync is the one that matters: a delta that failed against a stale baseline can be
        /// coalesced away, and if the model read its own reduction's resync flag instead of the apply's,
        /// the full frame that failed delta needed would never be requested and the pane would sit on a
        /// stale grid.
        func testACoalescedApplyInstallsTheNewestStateAndRequestsTheResyncItInherited() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let resyncResponse = TerminalStateResponseHolder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return await resyncResponse.current()
            }
            // An owner-interactive model, so the only `.state` request this test can produce is the resync
            // itself: the viewer already owns the session, so nothing takes it over or synchronizes it.
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            let newest = Self.outputState(title: "newest", emittedAt: "2026-06-04T14:23:35Z")
            let stored = try XCTUnwrap(model.latestState).merged(with: newest)
            await resyncResponse.set(Self.terminalStateResponse(stored))

            model.applyReducedStateForTesting(
                TerminalRemoteStateReductionOutput(
                    incomingPayload: newest,
                    reduction: TerminalRemoteStateReductionResult(
                        payload: newest, storedPayload: stored, decodedUpdate: nil, frameToApply: nil, dropReason: nil, didRequestResync: false),
                    reduceMS: 0, coalescedAwayCount: 2, inheritedResyncRequest: true))

            XCTAssertEqual(model.latestState?.title, "newest")
            XCTAssertTrue(model.isOwner)
            let requestedResync = try await waitForStateRequestCount(1, recorder: recorder)
            XCTAssertTrue(requestedResync, "an inherited resync must ask the daemon for a full frame")
            let stateRequestCount = await recorder.countStateRequests()
            XCTAssertEqual(stateRequestCount, 1)
        }

        /// A session producing payloads that cannot be reduced — a device-side restart window, say — asks
        /// for a resync on every one of them, and each of those `.state` reads costs the daemon a unicast
        /// full-frame export. The reads are paced at one per window, and the pacing discards nothing: the
        /// requests suppressed inside a window arm exactly one coalesced retry at its boundary, so a burst
        /// costs one read plus one retry rather than one read per payload.
        func testABurstOfUnappliablePayloadsCostsOneResyncReadPlusOneTrailingRetry() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let resyncResponse = TerminalStateResponseHolder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return await resyncResponse.current()
            }
            // An owner-interactive model, so the only `.state` requests this test can produce are the
            // resync reads themselves.
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.renderUpdateResyncIntervalForTesting = 0.2
            await resyncResponse.set(Self.terminalStateResponse(try XCTUnwrap(model.latestState)))

            for index in 0..<6 {
                let payload = Self.outputState(title: "unappliable-\(index)", emittedAt: "2026-06-04T14:23:4\(index)Z")
                let stored = try XCTUnwrap(model.latestState).merged(with: payload)
                model.applyReducedStateForTesting(
                    TerminalRemoteStateReductionOutput(
                        incomingPayload: payload,
                        reduction: TerminalRemoteStateReductionResult(
                            payload: payload, storedPayload: stored, decodedUpdate: nil, frameToApply: nil, dropReason: "missing_baseline",
                            didRequestResync: true), reduceMS: 0))
            }

            let didRetry = try await waitForStateRequestCount(2, recorder: recorder)
            XCTAssertTrue(didRetry, "the resyncs the throttle suppressed must still be answered by a retry at the window boundary")
            // Past two more windows, so a throttle that merely delayed the suppressed requests rather than
            // coalescing them would have sent the rest by now.
            try await Task.sleep(for: .milliseconds(500))
            let stateRequestCount = await recorder.countStateRequests()
            XCTAssertEqual(stateRequestCount, 2, "six unappliable payloads must cost one read plus one coalesced retry")
        }

        /// The resync read in flight when a NEW failure arms the trailing retry was issued before that
        /// failure, so it answers with the screen as the daemon captured it beforehand. That frame still
        /// applies — it is newer than the baseline the failure broke — so retiring the retry on any frame
        /// at all cancels a request for a gap this frame does not cover. The viewer is then parked on the
        /// older revision while the session sits at a newer one, and a session that goes quiet leaves the
        /// pane stale indefinitely. Only a frame at or past the failed delta's target retires the retry.
        func testAResyncResponseOlderThanTheFailureItRacedDoesNotRetireTheTrailingRetry() async throws {
            let recorder = DeviceAPIRequestRecorder()
            // The held read answers for revision 6, the screen as it was before either delta below failed;
            // the retry's read answers for revision 50, which covers both.
            let responder = HeldTerminalStateResponder(
                first: Self.terminalStateResponse(
                    try Self.framedState(text: "raced", sessionRevision: 6, ownerEpoch: 1, emittedAt: "2026-06-04T14:24:00Z")),
                later: Self.terminalStateResponse(
                    try Self.framedState(text: "fresh", sessionRevision: 50, ownerEpoch: 1, emittedAt: "2026-06-04T14:24:10Z")))
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return await responder.answer()
            }
            // An owner-interactive model, so the only `.state` requests this test can produce are the
            // resync reads themselves.
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.renderUpdateResyncIntervalForTesting = 0.2
            defer { model.stop() }
            // The frame the viewer holds, and the chain the deltas below break.
            await model.applyLatestState(
                try Self.framedState(text: "start", sessionRevision: 5, ownerEpoch: 1, emittedAt: "2026-06-04T14:23:45Z"), isOutOfBand: false)

            // The first delta fails and sends the resync read, which the mock holds open.
            await model.applyLatestState(
                try Self.unappliableDeltaState(baseRevision: 40, targetRevision: 41, ownerEpoch: 1, emittedAt: "2026-06-04T14:23:46Z"),
                isOutOfBand: false)
            let didRead = try await waitForStateRequestCount(1, recorder: recorder)
            XCTAssertTrue(didRead, "the first unappliable delta must send the resync read")

            // A second delta, targeting a higher revision, fails while that read is still in flight: the
            // retry it arms is owed a frame at or past revision 42.
            await model.applyLatestState(
                try Self.unappliableDeltaState(baseRevision: 41, targetRevision: 42, ownerEpoch: 1, emittedAt: "2026-06-04T14:23:47Z"),
                isOutOfBand: false)

            // The held read finally answers, with the pre-failure screen.
            await responder.release()

            let didRetry = try await waitForStateRequestCount(2, recorder: recorder)
            XCTAssertTrue(didRetry, "a frame older than the failure the retry was armed for must leave that retry owed")
            // The retry answered with revision 50, which covers revision 42, so the cycle ends there. Past
            // two more windows, so a retry left armed by the covering frame would have fired by now.
            try await Task.sleep(for: .milliseconds(500))
            let stateRequestCount = await recorder.countStateRequests()
            XCTAssertEqual(stateRequestCount, 2, "a frame that covers the failure retires the retry")
        }

        /// The software keyboard is handled entirely on the client: the surface reports a shorter rendered
        /// window and the same grid, so no resize reaches the daemon and no other client attached to the
        /// session reflows.
        func testAKeyboardToggleSendsNoResizeRequest() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            defer { model.stop() }

            model.updateViewportSize(columns: 80, rows: 40)
            let didResize = try await waitForTerminalControlAction(.resize, count: 1, recorder: recorder)
            XCTAssertTrue(didResize, "the pane's own grid is what resizes the session")

            model.noteKeyboardToggled(visible: true)
            model.noteRenderedViewportChanged(window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 0, rowOffset: 18, columns: 80, rows: 22))
            model.noteKeyboardToggled(visible: false)
            model.noteRenderedViewportChanged(window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 0, rowOffset: 0, columns: 80, rows: 40))

            // Comfortably past the 120 ms ownership-sync debounce a viewport change would have armed.
            try await Task.sleep(for: .milliseconds(400))
            let resizeCount = await recorder.countTerminalControlAction(.resize)
            XCTAssertEqual(resizeCount, 1, "a keyboard show and hide must add no resize round trip of their own")
            XCTAssertEqual(model.viewportRows, 40, "the grid the session holds is unchanged by the keyboard")
            XCTAssertEqual(model.renderedViewportWindow?.rows, 40, "the client is back to rendering every row it reported")
        }

        /// A viewport report that arrives while an earlier one's ownership-synchronization round trip is
        /// still running does not start a second resize; `scheduleOwnershipSynchronization`'s coalescing
        /// branch records it in `needsOwnershipSynchronizationAfterCurrentRun` instead, and the round trip
        /// reruns once the in-flight one settles, carrying the size the surface most recently reported
        /// rather than the one already in flight. No other test in this file drives this branch: every
        /// other ownership-sync test resizes exactly once per model.
        func testOwnershipSynchronizationCoalescesAViewportReportThatArrivesWhileOneIsAlreadyRunning() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let resize = HeldResizeResponder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .resize { await resize.waitForFirstResizeThenRelease() }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            defer { model.stop() }

            model.updateViewportSize(columns: 80, rows: 24)
            await resize.waitForFirstResizeStart()
            let didSendFirstResize = try await waitForTerminalControlAction(.resize, count: 1, recorder: recorder)
            XCTAssertTrue(didSendFirstResize, "the first viewport report must start the round trip")
            XCTAssertTrue(model.isSynchronizingOwnership, "the round trip already on the wire must be this run's own body")

            // Arrives while the first round trip's resize is held open, i.e. while `isSynchronizingOwnership`
            // is true: the coalescing branch must record this size rather than start a second round trip
            // on top of the one still running. `updateViewportSize` is synchronous, so both flags below are
            // read at the exact moment the coalescing decision was made rather than after some later settling.
            model.updateViewportSize(columns: 100, rows: 30)
            XCTAssertTrue(
                model.isSynchronizingOwnership,
                "the first run's own body must still be the one in flight; coalescing must not replace it with a second one")
            XCTAssertTrue(
                model.isOwnershipSynchronizationScheduled,
                "the coalesced report must still read as one schedule outstanding, not a second schedule stacked on top")

            // A held resize masks a broken coalescing decision here: the model's single
            // `SpacesDeviceAPICommandChannel` gates one round trip on the wire at a time, so a second,
            // uncoalesced resize attempt would queue behind this held one rather than reach the recorder —
            // a request count taken while held cannot tell "coalesced" apart from "queued behind the gate".
            // This is a sanity check on the one round trip already running, not the coalescing proof itself.
            try await Task.sleep(for: .milliseconds(150))
            let requestsWhileHeld = await recorder.countTerminalControlAction(.resize)
            XCTAssertEqual(requestsWhileHeld, 1, "a resize round trip already running must not start a second one")

            await resize.release()

            let didRerun = try await waitForTerminalControlAction(.resize, count: 2, recorder: recorder)
            XCTAssertTrue(didRerun, "the coalesced report must rerun the round trip once the running one settles")
            // The coalescing proof: releasing the gate lets anything that was queued behind it through. A
            // second, uncoalesced resize attempt started during the hold above would have been sitting right
            // behind this one, and would surface here as a third round trip once the gate frees — which the
            // request count taken while held could not have shown. The window must exceed that third round
            // trip's worst-case arrival: the follow-up run's 6×50 ms stream-settle loop plus the 120 ms
            // schedule debounce (~420 ms after the second request), or a broken second run slips past it.
            //
            // What this pins is the `isSynchronizingOwnership` coalescing guard itself. Deleting only the
            // `needsOwnershipSynchronizationAfterCurrentRun` write behind it is behaviorally masked here by
            // design: `shouldResynchronizeOwnership`'s viewport-mismatch fallback reruns to the same
            // [80, 100] sequence, so no request-level seam can tell the two apart in this scenario.
            try await Task.sleep(for: .milliseconds(900))
            let settledRequestCount = await recorder.countTerminalControlAction(.resize)
            XCTAssertEqual(settledRequestCount, 2, "the coalesced report must produce exactly one rerun, not an additional uncoalesced round trip")
            let requests = await recorder.snapshot()
            let resizedColumns = requests.compactMap { request -> Int? in
                guard case .terminalControl(let payload) = request.command, payload.action == .resize else { return nil }
                return payload.columns
            }
            XCTAssertEqual(
                resizedColumns, [80, 100], "the rerun must resize to the size reported while the first run was held, not the one already sent")
        }

        /// A stream payload naming this client owner can land before the takeover request it raced ever
        /// gets an answer: that response is only the acknowledgment of a mutation this client already
        /// made, and `applyReducedState`'s `takeover_confirmed_by_stream` branch reads ownership from the
        /// stream the instant it says so. The "taking over" affordance must clear right there rather than
        /// wait for the response, since a slow or dropped acknowledgment must not leave the pane reading as
        /// still-taking-over after the daemon has already handed this client the terminal.
        func testAStreamPayloadThatConfirmsOwnershipClearsTakingOverBeforeItsOwnTakeoverResponseReturns() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let takeover = HeldTakeoverResponder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .terminalControl(let payload) = request.command, payload.action == .takeover { await takeover.waitForReleaseAfterStarting() }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            // A starting session, so the viewer never auto-takes-over and the takeover below is the only
            // attempt: an automatic one would otherwise already be in flight and turn this into a no-op.
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            let takeoverTask = Task { await model.takeOver() }
            await takeover.waitForStart()
            // Not `isTakingOver`: `phase` checks `isStartingState` before the takeover flags, so a
            // session still reading `.starting` shows `.starting`, not `.takingOver`, even with the
            // attempt in flight. `isBusy` is set synchronously before the network call and is the
            // flag that actually reflects the attempt's in-flight state here.
            XCTAssertTrue(model.isBusy, "the attempt must read as busy once it is in flight")

            let ownerAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: model.remoteClientForTesting.id, mode: .owner, attachedAt: "2026-06-04T14:26:00Z")
            let confirmingState = try Self.framedState(
                text: "owned", sessionRevision: 1, ownerEpoch: 1, emittedAt: "2026-06-04T14:26:00Z",
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [model.remoteClientForTesting], attachments: [ownerAttachment]))
            await model.applyLatestState(confirmingState, isOutOfBand: false)

            XCTAssertTrue(model.isOwner, "the stream payload naming this client owner must be applied")
            // `phase` checks `isOwner` before the takeover flags, so `isTakingOver` (== phase == .takingOver)
            // and `keepsTerminalInputSurfaceActive` both read the same way here whether or not `isBusy` was
            // actually cleared: an owner is never `.takingOver`, and every owner phase (`.ownerBusy`,
            // `.ownerSynchronizing`, `.ownerInteractive`) keeps the input surface active. Neither assertion
            // would fail if the stream-confirmation clearing branch were deleted, so `isBusy` itself — the
            // flag that branch actually clears, and the one `takeOver()`'s own defer would otherwise leave
            // held until the still-open takeover response returns — is what pins the behavior below.
            XCTAssertFalse(model.isTakingOver, "ownership confirmed by the stream must clear the takeover affordance on its own")
            XCTAssertTrue(model.keepsTerminalInputSurfaceActive, "an owner past its takeover must keep the input surface active while still settling")
            XCTAssertFalse(
                model.isBusy, "the stream confirmation must clear the busy takeover presentation on its own, before its own takeover response returns"
            )

            await takeover.release()
            await takeoverTask.value
            XCTAssertTrue(model.isOwner)
            XCTAssertFalse(model.isTakingOver)
            let takeoverCount = await recorder.countTerminalControlAction(.takeover)
            XCTAssertEqual(takeoverCount, 1, "one manual takeover must send exactly one request even though the stream confirmed ownership first")
        }

        /// A revoked pairing tears the viewer down and sends the user to re-pair. A trailing resync armed
        /// before that revocation would dial the device again afterwards, fail authentication a second
        /// time, and ask the user to re-pair twice for one revocation, so the teardown cancels it.
        func testARevokedPairingCancelsTheTrailingResyncRetry() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let authenticationRecorder = AuthenticationPromptRecorder()
            // The device refuses this client outright, so the resync read below comes back as a revoked
            // pairing rather than a full frame.
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: false, message: "Invalid device auth token.", errorCode: .unauthorized)
            }
            // An owner-interactive model, so the only `.state` requests this test can produce are the
            // resync reads themselves.
            let model = TerminalViewerModel(
                session: session(), settings: settings(),
                onAuthenticationRequired: { message in Task { await authenticationRecorder.append(message) } }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.renderUpdateResyncIntervalForTesting = 0.2

            // Two unappliable payloads inside one throttle window: the first sends the resync read the
            // revoked pairing fails, the second arms the trailing retry behind it.
            for index in 0..<2 {
                let payload = Self.outputState(title: "unappliable-\(index)", emittedAt: "2026-06-04T14:23:5\(index)Z")
                let stored = try XCTUnwrap(model.latestState).merged(with: payload)
                model.applyReducedStateForTesting(
                    TerminalRemoteStateReductionOutput(
                        incomingPayload: payload,
                        reduction: TerminalRemoteStateReductionResult(
                            payload: payload, storedPayload: stored, decodedUpdate: nil, frameToApply: nil, dropReason: "missing_baseline",
                            didRequestResync: true), reduceMS: 0))
            }

            let authenticationMessage = try await waitForAuthenticationMessage(recorder: authenticationRecorder)
            XCTAssertEqual(authenticationMessage, "This Mac no longer recognizes this device. Open Devices and pair this device again.")
            // Past the trailing window, so a retry that outlived the teardown would have fired by now.
            try await Task.sleep(for: .milliseconds(500))
            let stateRequestCount = await recorder.countStateRequests()
            XCTAssertEqual(stateRequestCount, 1, "a viewer torn down by a revoked pairing must not dial the device again")
            let promptCount = await authenticationRecorder.count()
            XCTAssertEqual(promptCount, 1, "one revocation must ask the user to re-pair exactly once")
        }

        /// A `.state` response describes the session as it was when it was asked, and it re-enters beside a
        /// subscription that never stopped, so one that lands after the stream has already carried the
        /// viewer further is stale by construction. Applying it would walk the pane and its metadata
        /// backwards, so the refresh route submits out of band and the reducer refuses it.
        func testADelayedStateResponseDoesNotWalkTheViewerBackToOlderState() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                // The takeover is accepted but answers with no state, so the confirmation refresh below is
                // what carries the (stale) `.state` response into the model.
                if case .state = request.command {
                    return Self.terminalStateResponse(Self.outputState(title: "older", emittedAt: "2026-06-04T14:23:30Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            // A starting session, so the viewer never auto-takes-over and the takeover below is the only
            // one: the automatic attempt would otherwise be in flight and turn this one into a no-op.
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            await model.applyLatestState(Self.outputState(title: "newest", emittedAt: "2026-06-04T14:23:45Z"), isOutOfBand: false)

            // `takeOver` awaits its confirmation refresh, so the stale response has landed by the time this
            // returns — no settling window to wait out.
            await model.takeOver()

            let stateRequestCount = await recorder.countStateRequests()
            XCTAssertEqual(stateRequestCount, 1, "the takeover confirmation must have actually read state")
            XCTAssertEqual(model.latestState?.title, "newest", "a response older than what the stream already delivered must not be applied")
        }

        /// A refused response is kept on the reduction for its metrics and nothing else: the reducer moved
        /// no state, so `storedPayload` is the previous state untouched. The payload itself still carries
        /// the attachment and screen the session had when it was asked — before whatever superseded it —
        /// so an apply that read either off it would clear this viewer's own attachment (leaving the next
        /// dismissal with nothing to detach) and repaint the live owner epoch with the stale screen.
        func testARefusedStateResponseLeavesTheOwnersAttachmentAndScreenAlone() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 2)
            // The stream's own frame, which is what the response below is ordered against.
            await model.applyLatestState(
                try Self.framedState(text: "live", sessionRevision: 5, ownerEpoch: 2, emittedAt: "2026-06-04T14:23:45Z"), isOutOfBand: false)
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot, Self.snapshot(text: "live"))

            // A `.state` read answered before the handoff that made this client the owner, delivered after
            // the stream has carried the viewer past it: an older owner epoch, so the reducer refuses all
            // of it — screen, attachment snapshot and metadata alike.
            let previousOwner = TerminalClient(
                id: "mac-window", kind: .local, identity: TerminalClientIdentity(label: "Spaces"), connectedAt: "2026-06-04T14:23:30Z")
            let preHandoffSnapshot = TerminalSessionAttachmentSnapshot(
                clients: [previousOwner],
                attachments: [
                    TerminalAttachment(sessionID: "terminal-session", clientID: previousOwner.id, mode: .owner, attachedAt: "2026-06-04T14:23:30Z")
                ])
            await model.applyLatestState(
                try Self.framedState(
                    text: "pre-handoff", sessionRevision: 9, ownerEpoch: 1, emittedAt: "2026-06-04T14:23:40Z", attachmentSnapshot: preHandoffSnapshot),
                isOutOfBand: true)

            XCTAssertTrue(model.isOwner, "the refused payload's ownership must not replace the merged state's")
            XCTAssertEqual(
                model.ownerRenderEpoch?.bootstrapSnapshot, Self.snapshot(text: "live"),
                "a refused payload's screen must not reach the live owner render epoch")
            XCTAssertEqual(model.ownerRenderEpoch?.ownerEpoch, 2, "nor may it walk the epoch that every control request quotes backwards")

            // The attachment this viewer holds is only observable through what dismissing it does, so this
            // is the assertion that the refused snapshot did not rewrite it: a viewer that believes it is
            // no longer attached detaches nothing and leaves the session holding a dead client.
            model.stop()
            let didDetach = try await waitForTerminalControlAction(.detach, count: 1, recorder: recorder)
            XCTAssertTrue(didDetach, "a refused payload's attachment snapshot must not clear this viewer's own attachment")
        }

        /// The apply is not the only consumer of a `.state` response. `refreshLatestState` hands its return
        /// to the ownership handshake, which bootstraps the owner render epoch from it — and that epoch is
        /// what every input and resize request this viewer sends quotes. A refused response describes a
        /// session generation the stream has already left behind, so an epoch begun from it would stamp
        /// control requests with a number the daemon has moved past until some later stream frame reseeded
        /// it. The refusal has to reach the caller, not just the apply.
        func testAnOwnerBootstrapDoesNotBeginItsRenderEpochFromARefusedStateResponse() async throws {
            let recorder = DeviceAPIRequestRecorder()
            // Answered before the handoff that made this client the owner, so its frame carries an older
            // owner epoch and the reducer refuses the whole payload. Its snapshot matches the viewport set
            // below, which is exactly what makes it look like usable bootstrap state to anything reading
            // the response rather than the reduction.
            let staleResponse = Self.terminalStateResponse(
                try Self.framedState(text: "pre-handoff", sessionRevision: 9, ownerEpoch: 1, emittedAt: "2026-06-04T14:23:40Z"))
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .state = request.command { return staleResponse }
                guard case .terminalControl(let payload) = request.command, payload.action == .takeover, let clientID = payload.clientID else {
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                return Self.terminalStateResponse(Self.ownedState(clientID: clientID, emittedAt: "2026-06-04T14:23:46Z"))
            }
            // A starting session, so no automatic takeover races the one below, and the ownership handshake
            // it schedules is the only thing that reads `.state`.
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            // The stream's own frame, which is what the response above is ordered against.
            await model.applyLatestState(
                try Self.framedState(text: "live", sessionRevision: 5, ownerEpoch: 2, emittedAt: "2026-06-04T14:23:45Z"), isOutOfBand: false)

            await model.takeOver()
            XCTAssertTrue(model.isOwner, "the handshake under test only runs for an owner")
            // Drives the handshake's resize round trip, and sizes the viewport so the frame this viewer
            // already holds cannot serve as bootstrap state: the fetched one is the only candidate.
            model.updateViewportSize(columns: 11, rows: 1)

            let didRead = try await waitForStateRequestCount(1, recorder: recorder)
            XCTAssertTrue(didRead, "the handshake must have actually read state to bootstrap from")
            // The handshake asks again instead of settling, because a refused response bootstrapped
            // nothing and this owner still has no baseline to render from. The mock answers every read
            // with the same stale payload, so the retries continue for as long as the model lives; a real
            // session answers the next read with its current frame and the handshake settles on that.
            let didAskAgain = try await waitForStateRequestCount(2, recorder: recorder)
            XCTAssertTrue(didAskAgain, "a refused response is not a bootstrap, so the handshake must ask again rather than settle on it")
            XCTAssertNil(model.ownerRenderEpoch, "a refused response carries no usable owner state, so no epoch may be begun from it")
        }

        /// The partial refusal, which the whole-payload refusal above cannot stand in for. A response
        /// whose frame alone is superseded — same owner epoch, a revision this viewer already holds — has
        /// its metadata ordered separately, and that metadata genuinely merges, so the reduction reports no
        /// refusal and the caller is handed a payload. What that payload must not still carry is the
        /// refused frame: the handshake bootstraps the owner render epoch from whatever it is given, and a
        /// screen the reducer just declined is exactly what it must not seed from.
        func testAnOwnerBootstrapDoesNotSeedItsRenderEpochFromAPartiallyRefusedStateResponse() async throws {
            let recorder = DeviceAPIRequestRecorder()
            // The same owner epoch as the frame this viewer holds and a lower revision, so only the frame
            // is refused; a stamp newer than everything already reduced, so the payload's metadata merges
            // and the reduction is not a refusal. Its snapshot matches the viewport set below, which is
            // what makes it look like usable bootstrap state to anything reading the response rather than
            // the reduction.
            let supersededScreenResponse = Self.terminalStateResponse(
                try Self.framedState(text: "stale-frame", sessionRevision: 5, ownerEpoch: 2, emittedAt: "2026-06-04T14:23:47Z"))
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .state = request.command { return supersededScreenResponse }
                guard case .terminalControl(let payload) = request.command, payload.action == .takeover, let clientID = payload.clientID else {
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                return Self.terminalStateResponse(Self.ownedState(clientID: clientID, emittedAt: "2026-06-04T14:23:46Z"))
            }
            // A starting session, so no automatic takeover races the one below, and the ownership handshake
            // it schedules is the only thing that reads `.state`.
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            // The stream's own frame: the revision the response above is ordered against, and too narrow
            // for the viewport below to bootstrap from.
            await model.applyLatestState(
                try Self.framedState(text: "live", sessionRevision: 9, ownerEpoch: 2, emittedAt: "2026-06-04T14:23:45Z"), isOutOfBand: false)

            await model.takeOver()
            XCTAssertTrue(model.isOwner, "the handshake under test only runs for an owner")
            // Drives the handshake's resize round trip, and sizes the viewport so the frame this viewer
            // already holds cannot serve as bootstrap state: the fetched one is the only candidate.
            model.updateViewportSize(columns: 11, rows: 1)

            let didRead = try await waitForStateRequestCount(1, recorder: recorder)
            XCTAssertTrue(didRead, "the handshake must have actually read state to bootstrap from")
            // The handshake asks again instead of settling, because the response's only screen was refused
            // and this owner still has no baseline to render from. The mock answers every read with the
            // same superseded frame, so the retries continue for as long as the model lives; a real session
            // answers the next read with its current frame and the handshake settles on that.
            let didAskAgain = try await waitForStateRequestCount(2, recorder: recorder)
            XCTAssertTrue(didAskAgain, "a response whose frame was refused bootstrapped nothing, so the handshake must ask again")
            XCTAssertNil(model.ownerRenderEpoch, "a refused frame must not become the owner epoch's bootstrap snapshot")
        }

        /// The other family that reads a `.state` return: the recovery that asks whether the session it
        /// just failed to reach is simply gone. The reducer refuses an ended report only when it is
        /// provably answering for a superseded run — a different child PID, stamped older than what the
        /// stream already delivered — which is precisely the delayed exit report of a run that has since
        /// been relaunched. Believed, it would retire the failure as "this session ended" and leave the
        /// viewer parked on a live session it stopped reconnecting to.
        func testARefusedExitReportFromASupersededRunDoesNotEndTheSession() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let exitReportResponse = Self.terminalStateResponse(
                Self.runState(
                    childPID: 199, state: .exited, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-04T14:23:40Z"))
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .state = request.command { return exitReportResponse }
                guard case .terminalControl(let payload) = request.command, payload.action == .attach else {
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                // The attach the connect below starts with, answered for the run that already exited.
                return SpacesDeviceAPIResponse(ok: false, message: "The terminal session is not running.", errorCode: .sessionNotRunning)
            }
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            // The relaunched run as the stream reported it: a newer stamp, and a different child PID from
            // the exit report the read above answers with.
            await model.applyLatestState(
                Self.runState(
                    childPID: 200, state: .starting, reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-06-04T14:23:45Z"),
                isOutOfBand: false)

            model.start()

            // A viewer that accepted the exit report reports nothing and schedules no reconnect: it
            // believes the session it is looking at is over. Surfacing the connect failure is what says
            // the refusal reached the caller.
            await waitUntil("the failed connect to be reported") { model.errorMessage != nil }
            let stateRequestCount = await recorder.countStateRequests()
            XCTAssertGreaterThanOrEqual(stateRequestCount, 1, "the recovery must have actually read state")
        }

        /// The takeover response is the exception: it is the acknowledgment of a mutation this client just
        /// made and the only carrier of the attachment snapshot that names this device the owner, so it is
        /// submitted in band. Ordered as a `.state` response would be, a stream payload that raced it would
        /// refuse it on its timestamp alone and leave a successful takeover reading as unconfirmed.
        func testATakeoverResponseAppliesEvenWhenItIsStampedOlderThanTheStreamState() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command, payload.action == .takeover, let clientID = payload.clientID else {
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                return Self.terminalStateResponse(Self.ownedState(clientID: clientID, emittedAt: "2026-06-04T14:23:31Z"))
            }
            // A starting session, for the same reason as the test above: no automatic takeover races this
            // one.
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            await model.applyLatestState(Self.outputState(title: "newest", emittedAt: "2026-06-04T14:23:46Z"), isOutOfBand: false)

            await model.takeOver()

            XCTAssertTrue(model.isOwner, "the takeover's own attachment snapshot must apply however it is stamped")
            let stateRequestCount = await recorder.countStateRequests()
            XCTAssertEqual(stateRequestCount, 0, "a takeover that applied needs no confirmation read")
        }

        /// The daemon answers a takeover with the session's metadata and no screen, so the payload that
        /// confirms ownership carries no render update and therefore no owner epoch of its own. The resize
        /// the ownership handshake sends right after must not be stamped with the epoch of the owner this
        /// client displaced: the daemon accepts a nil epoch from the owner but rejects a mismatched one as
        /// stale, so a carried-forward stamp would drop the one resize that brings the session to the
        /// phone's grid, and the open would sit on the previous owner's size.
        func testTheResizeAfterAScreenlessTakeoverIsNotStampedWithTheDisplacedOwnersEpoch() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                guard case .terminalControl(let payload) = request.command, payload.action == .takeover, let clientID = payload.clientID else {
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                // Exactly the shape the Device API returns for a takeover: the attachment snapshot naming
                // this client the owner, and no render update.
                return Self.terminalStateResponse(Self.ownedState(clientID: clientID, emittedAt: "2026-06-04T14:23:31Z"))
            }
            // A starting session, so no automatic takeover races the explicit one below.
            let model = TerminalViewerModel(
                session: session(state: .starting), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            let displacedOwner = TerminalClient(
                id: "displaced-owner", kind: .remote, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:23:29Z")
            let displacedAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: displacedOwner.id, mode: .owner, attachedAt: "2026-06-04T14:23:29Z")
            await model.applyLatestState(
                try Self.framedState(
                    text: "mac", sessionRevision: 1, ownerEpoch: 1, emittedAt: "2026-06-04T14:23:30Z",
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [displacedOwner], attachments: [displacedAttachment])),
                isOutOfBand: false)
            XCTAssertFalse(model.isOwner, "the stream's frame must leave the other client owning the session")

            await model.takeOver()
            XCTAssertTrue(model.isOwner, "a screenless takeover response must still confirm ownership")

            model.updateViewportSize(columns: 40, rows: 30)

            let didResize = try await waitForTerminalControlAction(.resize, count: 1, recorder: recorder)
            XCTAssertTrue(didResize, "the ownership handshake must send the phone's grid after the takeover")
            let requests = await recorder.snapshot()
            let resize = try XCTUnwrap(
                requests.compactMap { request -> SpacesDeviceTerminalControlRequest? in
                    guard case .terminalControl(let payload) = request.command, payload.action == .resize else { return nil }
                    return payload
                }.first)
            XCTAssertNotEqual(
                resize.ownerEpoch, 1, "the displaced owner's epoch must not stamp the new owner's resize: the daemon would reject it as stale")
        }

        /// An owner whose stream drops reconnects silently, and the new subscription's deltas are computed
        /// against the daemon's baseline rather than the frame this viewer still holds. Nothing confirms
        /// those agree, so every connect bootstraps from a direct read — the owner's included, which is the
        /// only way `isOwner` can be true this early. Without it the divergence surfaces only when a delta
        /// fails, costing a wrong-frame window plus the resync round trip.
        func testAnOwnerReconnectBootstrapsFromADirectStateRead() async throws {
            let streamServer = try HoldOpenTCPServer()
            defer { streamServer.stop() }
            var settings = settings()
            settings.port = streamServer.port
            let recorder = DeviceAPIRequestRecorder()
            let bootstrapResponse = TerminalStateResponseHolder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if case .state = request.command { return await bootstrapResponse.current() }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await bootstrapResponse.set(Self.terminalStateResponse(try XCTUnwrap(model.latestState)))
            XCTAssertTrue(model.isOwner)
            defer { model.stop() }

            model.start()

            let didBootstrap = try await waitForStateRequestCount(1, recorder: recorder)
            XCTAssertTrue(didBootstrap, "an owner's reconnect must confirm its baseline with a direct read")
            XCTAssertTrue(model.isOwner, "the bootstrap read must not disturb ownership")
        }

        /// A viewer that has been stopped has already released its stream, its queued input, and its
        /// attachment. A payload the pipeline was still reducing when that happened must land nowhere:
        /// installing it would put the session's attachment back and leave the next visit believing it is
        /// still attached.
        func testAStoppedViewerDropsAnApplyThatWasStillInTheReducer() async {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            await model.applyLatestState(Self.outputState(title: "before-stop", emittedAt: "2026-06-04T14:23:36Z"), isOutOfBand: false)

            model.stop()
            let afterStop = Self.outputState(title: "after-stop", emittedAt: "2026-06-04T14:23:37Z")
            model.applyReducedStateForTesting(
                TerminalRemoteStateReductionOutput(
                    incomingPayload: afterStop,
                    reduction: TerminalRemoteStateReductionResult(
                        payload: afterStop, storedPayload: afterStop, decodedUpdate: nil, frameToApply: nil, dropReason: nil, didRequestResync: false),
                    reduceMS: 0))

            XCTAssertEqual(model.latestState?.title, "before-stop")
        }

        /// `noteStateApplied` runs from the `defer` at the very top of `applyReducedState`, ahead of the
        /// `isStopping` guard that drops everything else about a payload reduced after `beginStop()`, so
        /// stopping the model can never strand a caller that is awaiting `applyLatestState` for that
        /// payload. This starts the wait and stops the model before the real, off-main reduction pipeline
        /// has had any chance to reduce or apply the payload — `stop()` runs synchronously on the same
        /// main actor as this test method, which has not yet suspended, so it always lands first — then
        /// confirms the wait still resolves instead of hanging. Moving `noteStateApplied` below the
        /// `isStopping` guard would make this test hang until XCTest's own timeout fails it.
        func testAnAwaitedApplyReleasesItsWaiterEvenWhenTheModelStopsBeforeItLands() async {
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in })
            let payload = Self.outputState(title: "after-stop-wait", emittedAt: "2026-06-04T14:23:38Z")
            let waiterBox = WaiterReleaseBox()
            let waitingTask = Task {
                await model.applyLatestState(payload, isOutOfBand: false)
                waiterBox.released = true
            }

            model.stop()

            await waitUntil("the stop-time apply to release its waiter") { waiterBox.released }
            XCTAssertNil(model.latestState, "a payload reduced after stop must still be dropped, not applied")
            _ = await waitingTask.value
        }

        /// The viewer's reaction to the stream liveness watch firing. A stalled stream is a transport that
        /// died under a connection that still looks open, so the only fix is a new stream — and while the
        /// last frame is still on screen the user must not be shown an error for a reconnect that is about
        /// to succeed on its own.
        ///
        /// The banner must stay hidden through all of this: overriding the grace to something the test's
        /// own timeout cannot outlast proves the silence is because the reconnect never crossed the grace
        /// at all, not merely that it happened to beat a race against a live timer.
        func testAStalledStreamReconnectsSilentlyWithoutReportingAnError() async throws {
            let backend = StalledStreamBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)

            await backend.reportDisconnect(SpacesDeviceAPIClientError.streamStalled)

            let resubscribed = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(resubscribed, "a stalled stream is only recoverable by opening a new one")
            XCTAssertNil(model.errorMessage, "a stall with a frame still on screen must reconnect silently")
            XCTAssertFalse(model.isConnectionBannerVisible, "a reconnect this fast must never surface the banner")
            XCTAssertEqual(model.connectionStage, .reconnecting, "no frame has landed on the new stream yet, so the stage stays reconnecting")
        }

        /// Stage 1's whole point is absorbing an ordinary blip without flashing anything: the banner must
        /// stay hidden for exactly as long as `connectionBannerGraceSecondsForTesting` says, then appear
        /// once the grace elapses on a stream that is still down.
        func testConnectionBannerAppearsOnlyAfterGraceElapsesOnStreamLoss() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 0.2
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)

            await waitUntil("the stage to move to reconnecting") { model.connectionStage == .reconnecting }
            XCTAssertFalse(model.isConnectionBannerVisible, "the grace has not elapsed yet")

            await waitUntil("the banner to appear once the grace elapses", timeout: .seconds(2)) { model.isConnectionBannerVisible }
            XCTAssertEqual(model.connectionStage, .reconnecting)
            XCTAssertNil(model.errorMessage)
        }

        /// A frame is the only thing that ever clears stage 1 or stage 2, never a timer. Once the banner
        /// is on screen, the very next frame on the stream must drop both the stage and the banner
        /// immediately.
        func testConnectionBannerAndStageClearAsSoonAsAFrameArrives() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 0.05
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the banner to appear", timeout: .seconds(2)) { model.isConnectionBannerVisible }
            // Firing the frame on the stream that just disconnected would not count: the model discards
            // any event that arrives on a superseded reconnect attempt (`isCurrentConnect`), just as it
            // would for a real socket. Wait for the automatic reconnect's resubscribe first, so the frame
            // lands on the connection the model actually considers current.
            let resubscribed = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(resubscribed, "the model must redial after a transient disconnect even before the banner's own grace elapses")

            await backend.fireFrame(Self.outputState(title: "resumed", emittedAt: "2026-06-04T14:23:40Z"))

            await waitUntil("the stage to return to connected") { model.connectionStage == .connected }
            XCTAssertFalse(model.isConnectionBannerVisible, "a frame must clear the banner immediately, not on a timer")
        }

        /// A device that comes back reachable while its session ended in the meantime never delivers
        /// another stream frame: `registerLiveStreamFrame()` is the only thing that clears the tracker,
        /// and no frame can ever arrive for an ended session. The redial that discovers this fails with
        /// the daemon's "no live state stream" error and falls back to `recoverEndedStateIfLiveStreamIsMissing`'s
        /// own state fetch, which is what must clear the banner once it lands.
        func testMissingLiveStreamRecoveryToEndedStateClearsTheBanner() async throws {
            let transport = EndedStateAfterMissingLiveStreamTransport()
            let backend = StageTrackerTestBackend(transportFactory: { transport })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 0.05
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the banner to appear", timeout: .seconds(2)) { model.isConnectionBannerVisible }

            // The device answers back, but the session already ended while it was unreachable: the
            // scheduled redial itself is refused with the daemon's missing-live-stream error, and only the
            // state fetch that recovery falls back to can prove the outage is over.
            await backend.setNextSubscribeError(SpacesDeviceAPIClientError.requestFailed("no live state stream", code: nil))
            await transport.setAnswerEnded(true)

            await waitUntil("the stage to return to connected once the ended state loads", timeout: .seconds(5)) {
                model.connectionStage == .connected
            }
            XCTAssertFalse(
                model.isConnectionBannerVisible, "the device answered with the session's final state; nothing remains for the banner to report")
            XCTAssertEqual(model.renderMode, "ended", "the recovered state must actually be the session's ended state")
        }

        /// The input-path sibling of `testMissingLiveStreamRecoveryToEndedStateClearsTheBanner`: the
        /// device comes back reachable with the session ended, but this time it is a keystroke, not the
        /// redial, that learns it first. The daemon refuses the input with `sessionNotRunning`, which
        /// routes to `recoverEndedStateAfterTerminalStopped`'s own state fetch; that fetch is the last
        /// thing that can ever prove the outage over, since no stream frame arrives for an ended session.
        func testInputRefusedForAnEndedSessionRecoveryClearsTheBanner() async throws {
            let transport = EndedSessionRefusesInputRequestTransport()
            let backend = StageTrackerTestBackend(transportFactory: { transport })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 0.05
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the banner to appear", timeout: .seconds(2)) { model.isConnectionBannerVisible }

            await transport.setSessionEnded(true)
            await model.sendKey("a")

            await waitUntil("the stage to return to connected once the ended state loads", timeout: .seconds(5)) {
                model.connectionStage == .connected
            }
            XCTAssertFalse(
                model.isConnectionBannerVisible, "the device answered with the session's final state; nothing remains for the banner to report")
            XCTAssertEqual(model.renderMode, "ended", "the recovered state must actually be the session's ended state")
            XCTAssertNil(model.errorMessage, "a refused input for an ended session is recovered, never surfaced as an error")
        }

        /// An ended session can be learned through any state apply, not only the two recovery paths above:
        /// an ordinary out-of-band refresh (a foreground refresh, a reconnect's own bootstrap read) can
        /// land an ended payload while the outage banner is up. `applyReducedState`'s `isEndedState` block
        /// cancels the stream and the reconnect task, after which the disconnect that cancel triggers
        /// returns early (`isEndedState` is true), so nothing else in that path ever calls
        /// `clearConnectionOutage()`. Before the fix, this left a stale "Device unreachable" banner over
        /// the ended view forever.
        func testAnEndedStateAppliedFromARefreshClearsTheOutageBanner() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the banner to appear", timeout: .seconds(2)) { model.isConnectionBannerVisible }

            // A newer `emittedAt` than the owner payload's "2026-01-01T00:00:00Z" so the reducer accepts
            // it as an out-of-band refresh would.
            let endedPayload = Self.runState(
                childPID: 200, state: .exited, reason: TerminalRemoteSessionStateReason.terminated.rawValue, emittedAt: "2026-06-04T14:23:50Z")
            await model.applyLatestState(endedPayload, isOutOfBand: true)

            XCTAssertEqual(model.renderMode, "ended", "the applied state must actually be the session's ended state")
            XCTAssertEqual(model.connectionStage, .connected)
            XCTAssertFalse(
                model.isConnectionBannerVisible,
                "an ended state applied from any refresh, not just the two dedicated recovery paths, must clear the outage banner")
        }

        /// The only thing allowed to put the tracker into stage 2 is hard evidence: every candidate
        /// address failed to dial, never a timer. A grace long enough that this test's own timeout could
        /// never outlast it proves the jump bypasses the grace entirely rather than merely beating it.
        func testAllCandidatesUnreachableJumpsStraightToStage2WithoutGrace() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.setNextSubscribeError(SpacesDeviceAPIClientError.allCandidatesUnreachable(hosts: ["127.0.0.1"]))
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)

            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }
            XCTAssertTrue(model.isConnectionBannerVisible, "stage 2 shows the banner immediately, with no grace")
            XCTAssertNil(model.errorMessage, "an exhausted-candidates failure is transport-class and must never surface as errorMessage")
        }

        /// P1 regression: a fast dial failure can report through `onDisconnect` before `connect()`'s own
        /// `subscribe()` call has resumed and installed the returned handle onto `streamHandle`, since
        /// both that installation and the disconnect callback are ordinary main-actor jobs racing each
        /// other. Before `dialExhaustedAllCandidates` traveled on the disconnect event itself, the verdict
        /// lived on the handle, and a failure arriving this early found no handle yet to stamp it onto,
        /// silently losing real "every candidate is down" evidence and leaving the model stuck at stage 1.
        /// `setFailNextSubscribeBeforeReturningHandle(exhausted:)` reproduces that exact ordering: the
        /// redial's `onDisconnect` fires from inside `openSessionStream`, before it returns its handle.
        func testADialFailureReportedBeforeTheHandleIsInstalledStillCountsAsUnreachable() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.fireFrame(Self.outputState(title: "live", emittedAt: "2026-06-04T14:23:35Z"))
            await waitUntil("the stage to read connected once the frame lands") { model.connectionStage == .connected }

            // The stall below triggers an automatic redial. That redial is set up to report a transport
            // failure, with every candidate already exhausted, through `onDisconnect` before it ever
            // returns its handle to `connect()`: exactly the race a fast dial failure can win against
            // `connect()` installing `streamHandle`.
            await backend.setFailNextSubscribeBeforeReturningHandle(exhausted: true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)

            // The stall's own redial does not fire immediately: `handleDisconnect` schedules it after
            // `scheduleReconnect(after: .seconds(1))` for an ordinary (non-silent) stage 1 loss, so the
            // second `openSessionStream` call, and the race it reproduces, cannot land before that delay
            // elapses. This mirrors the timeout the sibling stage 2 tests above use for the same reason.
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }
            XCTAssertTrue(
                model.isConnectionBannerVisible,
                "the exhausted verdict carried on the disconnect event must still count even though it arrived before the handle did")
        }

        /// `SpacesDeviceAPIClientError.isStreamHostTransportFailure` (see `SpacesDeviceAPIClient.swift`)
        /// treats a stream ending with `NWError.dns` or a non-pin `NWError.tls` as transport failure, so
        /// the resolver records the host as failed and the disconnect event can carry
        /// `dialExhaustedAllCandidates: true`. Before `isTransientReconnectError` also recognized those
        /// two `NWError` cases, it only read POSIX-coded failures, so a stream ending this way was not
        /// transient: `handleDisconnect` fell into the `errorMessage = error.localizedDescription` branch
        /// instead of the tracker path, discarding the exhaustion verdict and showing the red error row
        /// instead of the stage 2 banner.
        func testADNSFailureOnTheStreamWithEveryCandidateExhaustedReachesUnreachableNotTheErrorRow() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)

            // The stream never delivers a frame and ends with `NWError.dns`, with every candidate already
            // exhausted: the same shape a name that stops resolving produces on a real dial.
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(NWError.dns(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord)))

            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }
            XCTAssertNil(model.errorMessage, "a DNS failure with every candidate exhausted must route to the banner, not the error row")
            XCTAssertTrue(model.isConnectionBannerVisible)

            let redialed = await backend.waitForSubscribeCount(2, timeout: .seconds(3))
            XCTAssertTrue(redialed, "the stage 2 ladder's automatic redial must still fire on schedule")
        }

        /// P2 regression: `beginStop()` used to cancel only the grace and probe tasks, leaving
        /// `connectionStageTracker`, `connectionStage`, and `isConnectionBannerVisible` however stage 2
        /// had left them. A retained detail stopped while `.unreachable` and later restarted would show
        /// the stale banner immediately and resume the old stage 2 backoff ladder, even though the new
        /// run has not observed any failure of its own yet. `beginStop()` now routes through
        /// `clearConnectionOutage()`, the same reset a live frame or an ended-state load uses, so a stop
        /// always leaves the next `start()` a clean lifecycle.
        func testStoppingTheViewerClearsTheOutageSoARestartBeginsClean() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.setNextSubscribeError(SpacesDeviceAPIClientError.allCandidatesUnreachable(hosts: ["127.0.0.1"]))
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }
            XCTAssertTrue(model.isConnectionBannerVisible, "sanity check: the outage must actually be showing before stop is asked to clear it")

            model.stop()
            XCTAssertEqual(model.connectionStage, .connected, "a stop is the end of this run's lifecycle, not evidence about the connection")
            XCTAssertFalse(model.isConnectionBannerVisible, "stop must clear the banner immediately, not leave it for the next start() to inherit")

            model.start()
            XCTAssertEqual(
                model.connectionStage, .connected, "start() must not itself resume whatever stage the lifecycle that was stopped had reached")
            XCTAssertFalse(model.isConnectionBannerVisible, "the restarted lifecycle has observed no failure of its own yet")
        }

        /// A stream dial failure never throws the command channel's racing `allCandidatesUnreachable`:
        /// `SpacesDeviceNetworkBackend.openSessionStream` hands back a handle before the `NWConnection`
        /// dials, so a failed dial always arrives later through `onDisconnect`, never through the
        /// subscribe call's own thrown error. `handleDisconnect` must consult the disconnect event's own
        /// `dialExhaustedAllCandidates` verdict as its own stage 2 evidence, or a stream that disconnects
        /// after the viewer has already attached could never reach stage 2 at all. That evidence only
        /// counts for a redial that itself never delivered a frame: the first stream here stalls before
        /// delivering one (stage 1, an ordinary redial), and only the redial's own stream, which also
        /// never delivers a frame before it ends, combines with the resolver's exhausted-candidate report
        /// to jump straight to stage 2.
        func testExhaustedStreamCandidatesReportedThroughDisconnectJumpsStraightToStage2() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            // The first stream stalls before ever delivering a frame. On its own this is not exhausted-
            // candidate evidence, so it must land at stage 1 and trigger an ordinary redial.
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to move to reconnecting") { model.connectionStage == .reconnecting }
            XCTAssertFalse(model.isConnectionBannerVisible, "the first stall alone is not stage 2 evidence")

            let resubscribed = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(resubscribed, "an ordinary stage 1 stall must still redial automatically")

            // The redial's own stream also never delivers a frame before it disconnects, and by then the
            // resolver reports every candidate exhausted: this is the hard evidence that jumps straight
            // to stage 2 with no further grace.
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)

            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }
            XCTAssertTrue(model.isConnectionBannerVisible, "stage 2 shows the banner immediately, with no grace")
            XCTAssertNil(model.errorMessage)
        }

        /// `handleDisconnect` must use the exhaustion verdict captured on the handle at disconnect time,
        /// never a fresh query made afterward: `SpacesDeviceEndpointResolver` is shared per device across
        /// every pane's stream, so another pane's own redial can land between this stream's failure and a
        /// later query and self-reset the resolver's failed-host set, silently erasing real "every
        /// candidate is down" evidence a re-query would have missed. `fireDisconnect(_:exhaustedOverride:)`
        /// reproduces exactly that shape: the handle carries a captured `true` verdict, while
        /// `allStreamCandidatesFailed` -- the backend's own "live" state, what a later query would read --
        /// is left `false` for the whole test. A model that re-derived the verdict instead of using the
        /// captured one would read `false` and stay stuck at stage 1; reading the captured value off the
        /// handle still escalates straight to stage 2 on this stream's very first, frame-less disconnect.
        func testDisconnectCarryingExhaustedVerdictEscalatesEvenWhenBackendsLiveSetReadsFalse() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            // Never delivers a frame, and the backend's own live flag stays false throughout: only the
            // handle's captured verdict says every candidate is exhausted.
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled, exhaustedOverride: true)

            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }
            XCTAssertTrue(model.isConnectionBannerVisible, "the verdict captured on the handle, not a live re-query, must drive stage 2")
        }

        /// F1 regression: a stream that delivered at least one frame and later stalls is only stage 1
        /// evidence, even when the resolver reports every candidate exhausted, because that exhaustion
        /// describes some other, unrelated dial, not this stream's own: this stream already proved it
        /// could reach the device. Before gating `handleDisconnect`'s evidence check on
        /// `currentStreamDeliveredFrame`, any errored disconnect whose event carried
        /// `dialExhaustedAllCandidates: true` jumped straight to stage 2, even for a stream that had
        /// been happily delivering frames moments earlier.
        func testStreamThatDeliveredAFrameThenStalledStaysAtStage1DespiteExhaustedCandidates() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.fireFrame(Self.outputState(title: "live", emittedAt: "2026-06-04T14:23:35Z"))
            await waitUntil("the stage to read connected once the frame lands") { model.connectionStage == .connected }

            // Only now does the resolver report every candidate exhausted, describing some later,
            // unrelated dial attempt. This stream already delivered a frame, so its own stall must not
            // borrow that evidence.
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)

            await waitUntil("the stage to move to reconnecting") { model.connectionStage == .reconnecting }
            XCTAssertFalse(model.isConnectionBannerVisible, "a stream that already delivered a frame must not skip the grace")
            XCTAssertNotEqual(
                model.connectionStage, .unreachable, "candidate exhaustion describes a different dial, not this stream's own already-proven-live one")
        }

        /// Negative case for the same evidence: a disconnect with an untried candidate left must not jump
        /// the grace, proving the escalation above is driven by the resolver's evidence and not merely by
        /// every disconnect.
        func testDisconnectWithUntriedStreamCandidatesStaysAtStage1() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            // A grace this long makes the assertion below unambiguous: reaching `.reconnecting` with the
            // banner still hidden this soon is only possible without a wrongful stage 2 jump.
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.setAllStreamCandidatesFailed(false)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)

            await waitUntil("the stage to move to reconnecting") { model.connectionStage == .reconnecting }
            XCTAssertFalse(model.isConnectionBannerVisible, "no stage 2 evidence: this must behave like any other stage 1 loss")
        }

        /// Regression test for the reset-before-subscribe fix in `connect()`: the subscription's first
        /// frame can arrive, and run `registerLiveStreamFrame()`, before `bridgeClient.subscribe(...)`
        /// even returns its handle to `connect()`, since the closure runs on the MainActor while
        /// `connect()` is still suspended awaiting that call. Before the fix, the `currentStreamDeliveredFrame
        /// = false` reset ran only after `subscribe()` returned, so it silently overwrote a delivery that
        /// had already landed for this same attempt. On a single-host device with every stream candidate
        /// already exhausted, that stale reset makes the very next stall read as a dial failure and jumps
        /// straight to `.unreachable` instead of the ordinary stage 1 `.reconnecting`.
        func testFrameDeliveredBeforeSubscribeReturnsCountsForThatAttempt() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            // Single-host device: every candidate is already exhausted before `connect()` even starts, so
            // whether the stall below reads as stage 1 or stage 2 hinges entirely on whether this stream's
            // own early frame was counted.
            await backend.setAllStreamCandidatesFailed(true)
            await backend.setDeliverInitialFrameBeforeReturningHandle(Self.outputState(title: "live", emittedAt: "2026-06-04T14:23:31Z"))

            // A sentinel, not the banner or subscribe count: `connectionStage` already defaults to
            // `.connected` before `start()` ever runs, and `waitForSubscribeCount` can observe `subscribe`
            // having merely been *entered* on the backend actor before the early frame it delivers has
            // actually reached the model, since `subscribeCount` is incremented ahead of that delivery.
            // `connect()` clears `errorMessage` in the same synchronous stretch as (and strictly after)
            // the `currentStreamDeliveredFrame` reset, with no suspension point between them in either the
            // buggy or the fixed ordering, so waiting for the sentinel to clear proves `connect()` has
            // resumed past that reset -- deterministically, not by racing the model's own scheduling.
            model.errorMessage = "sentinel-awaiting-connect"
            model.start()
            await waitUntil("connect() to resume past the currentStreamDeliveredFrame reset") { model.errorMessage == nil }

            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)

            await waitUntil("the connection stage to settle after the stall") { model.connectionStage != .connected }
            XCTAssertEqual(
                model.connectionStage, .reconnecting,
                "the frame delivered before subscribe() returned must still count as proof this stream reached the device")
        }

        /// A clean stream end (`error == nil`, e.g. the daemon restarting) is exactly as much evidence of
        /// a lost connection as a transient error: it must not fall through to `scheduleReconnect`
        /// untouched, leaving the banner unable to appear at all.
        func testCleanDisconnectWhileRunningShowsTheBannerAfterGrace() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 0.2
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.fireDisconnect(nil)

            await waitUntil("the stage to move to reconnecting") { model.connectionStage == .reconnecting }
            XCTAssertFalse(model.isConnectionBannerVisible, "the grace has not elapsed yet")
            await waitUntil("the banner to appear once the grace elapses", timeout: .seconds(2)) { model.isConnectionBannerVisible }
            XCTAssertEqual(model.connectionStage, .reconnecting)
            XCTAssertNil(model.errorMessage)
        }

        /// Retry is the escape hatch out of stage 2: it must redial immediately, not wait out whatever rung
        /// the automatic backoff ladder had reached.
        func testRetryConnectionRedialsImmediatelyFromUnreachable() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.setNextSubscribeError(SpacesDeviceAPIClientError.allCandidatesUnreachable(hosts: ["127.0.0.1"]))
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }

            model.retryConnection()

            // The automatic backoff's first rung is 1s; a redial inside a fraction of that proves Retry
            // skipped the ladder rather than merely winning a race with it.
            let redialed = await backend.waitForSubscribeCount(3, timeout: .milliseconds(500))
            XCTAssertTrue(redialed, "Retry must redial immediately rather than waiting out the backoff ladder")
        }

        /// Retry can land after an automatic redial has already dialed successfully but not yet delivered
        /// a frame: stage 2 has no timer gate on `connect()` itself, only on entering the stage, so a
        /// redial can install a live `streamHandle` while `connectionStage` is still `.unreachable`. Retry
        /// must cancel and drop that handle before scheduling its own redial, or `SpacesDeviceAPIStreamHandle`
        /// (which never cancels on deinit) leaks the connection every time Retry is tapped ahead of a
        /// redial's first frame.
        func testRetryConnectionCancelsAStreamAnAutomaticRedialAlreadyInstalled() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.setNextSubscribeError(SpacesDeviceAPIClientError.allCandidatesUnreachable(hosts: ["127.0.0.1"]))
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }

            // Let the automatic redial (the backoff ladder's first rung, 1s) actually dial:
            // `nextSubscribeError` was already consumed by the attempt that escalated to unreachable above,
            // so this one succeeds and installs a real stream, but nothing here ever calls `fireFrame`, so
            // it never delivers one and `connectionStage` stays `.unreachable`, exactly as it would while
            // still waiting on the daemon's initial state event.
            let redialInstalled = await backend.waitForSubscribeCount(3, timeout: .seconds(3))
            XCTAssertTrue(redialInstalled, "the automatic redial must have dialed successfully before Retry is tapped")
            XCTAssertEqual(model.connectionStage, .unreachable, "no frame has arrived yet, so the stage must not have moved")

            model.retryConnection()

            let cancelledTheInstalledStream = await backend.waitForCancelCount(1, timeout: .seconds(2))
            XCTAssertTrue(cancelledTheInstalledStream, "Retry must cancel the stream an automatic redial already installed")

            let retryRedialed = await backend.waitForSubscribeCount(4, timeout: .milliseconds(500))
            XCTAssertTrue(retryRedialed, "Retry must still redial immediately on top of the cancel")

            // Give any stray late callback from the cancelled stream's `onDisconnect` a moment to land
            // before confirming no second, spurious redial followed it: `scheduleReconnect` bumps
            // `reconnectAttemptGeneration` ahead of installing Retry's own redial, so that callback's
            // captured generation is already stale by the time it could fire, and `isCurrentConnect` (see
            // `connect()`'s `onDisconnect` closure) discards it.
            try? await Task.sleep(for: .milliseconds(200))
            let subscribeCountAfterSettling = await backend.currentSubscribeCount()
            XCTAssertEqual(subscribeCountAfterSettling, 4, "exactly one live subscription must remain after Retry, not a leaked second one")
            let cancelCountAfterSettling = await backend.currentCancelCount()
            XCTAssertEqual(cancelCountAfterSettling, 1, "only the one stream Retry replaced must have been cancelled")
        }

        /// Every failure this model reacts to routes to exactly one place: a transport-class failure
        /// (anything `isTransientReconnectError` recognizes) only ever drives the stage tracker, never
        /// `errorMessage`; anything else keeps using the existing red `errorMessage` row, untouched by the
        /// stage tracker.
        func testTransportClassErrorsRouteOnlyToTheBannerNeverToErrorMessage() async throws {
            let transientBackend = StageTrackerTestBackend()
            let transientBridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: transientBackend)
            let transientModel = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: transientBridgeClient)
            defer { transientModel.stop() }
            transientModel.connectionBannerGraceSecondsForTesting = 30
            await transientModel.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)
            transientModel.start()
            await transientBackend.waitForSubscribeCount(1)
            await transientBackend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to move to reconnecting") { transientModel.connectionStage == .reconnecting }
            XCTAssertNil(transientModel.errorMessage, "a transport-class failure must never populate errorMessage")

            let hardFailureBackend = StageTrackerTestBackend()
            let hardFailureBridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: hardFailureBackend)
            let hardFailureModel = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: hardFailureBridgeClient)
            defer { hardFailureModel.stop() }
            await hardFailureModel.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)
            hardFailureModel.start()
            await hardFailureBackend.waitForSubscribeCount(1)
            await hardFailureBackend.fireDisconnect(SpacesDeviceAPIClientError.requestFailed("synthetic hard failure", code: nil))

            await waitUntil("the hard failure to surface") { hardFailureModel.errorMessage != nil }
            XCTAssertEqual(hardFailureModel.connectionStage, .connected, "a non-transport failure must not touch the connection stage tracker")
            XCTAssertFalse(hardFailureModel.isConnectionBannerVisible)
        }

        /// Typing must never be held back by the banner: an input attempt still sends while the banner is
        /// on screen, and pulses the banner as visible acknowledgement of the attempt.
        func testInputStillSendsAndPulsesTheBannerWhileItIsVisible() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 0.05
            model.start()
            await backend.waitForSubscribeCount(1)
            // Ownership is granted only after the stream is up, so the bootstrap read `connect()` performs
            // on a fresh subscribe (an empty attachment snapshot) cannot clobber this synthetic ownership.
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the banner to appear", timeout: .seconds(2)) { model.isConnectionBannerVisible }
            let pulseCountBeforeSend = model.connectionBannerPulseCount

            await model.sendKey("a")

            await waitUntil("the send to pulse the visible banner") { model.connectionBannerPulseCount > pulseCountBeforeSend }
            try? await Task.sleep(for: .milliseconds(50))
            XCTAssertNil(model.errorMessage, "a send answered ok must still succeed while the banner is up")
        }

        /// The pulse has to acknowledge THIS keystroke, not whichever keystroke happens to reach the head
        /// of the serial input queue. With an earlier send stalled at the head of the queue, a second
        /// keystroke's own queued item cannot start running until the stalled one finishes, so a pulse
        /// fired from inside the queued closure (the pre-fix behavior) would never fire for the second
        /// keystroke at all here. Pulsing at enqueue time, before the item joins the queue, fires it
        /// immediately regardless of what the queue is doing.
        func testASecondKeystrokePulsesImmediatelyEvenWhileAnEarlierSendIsStalled() async throws {
            let backend = StageTrackerTestBackend(transportFactory: { StallFirstKeySendRequestTransport() })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 0.05
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the banner to appear", timeout: .seconds(2)) { model.isConnectionBannerVisible }
            let pulseCountBeforeAnySend = model.connectionBannerPulseCount

            // The first keystroke's own send stalls forever inside the transport; its enqueue-time pulse
            // still fires before that stall is ever reached.
            await model.sendKey("a")
            await waitUntil("the first send to pulse") { model.connectionBannerPulseCount > pulseCountBeforeAnySend }
            let pulseCountAfterFirstSend = model.connectionBannerPulseCount

            // The second keystroke is now queued behind the stalled first send, which never resolves.
            await model.sendKey("b")

            await waitUntil("the second send to pulse immediately, while the first send is still stalled") {
                model.connectionBannerPulseCount > pulseCountAfterFirstSend
            }
        }

        /// A bare request timeout on a stream the tracker still believes is `.connected` is inconclusive on
        /// its own: it could just be an ordinary slow round trip, so before treating it as a lost
        /// connection the viewer corroborates with a ping pinned to the stream's own host. An answered
        /// probe leaves the connection alone; a failed probe tears the stream down through the exact same
        /// path a stalled stream does.
        func testInputTimeoutIsCorroboratedWithAPingBeforeDecidingTheStreamIsLost() async throws {
            let answeredBackend = StageTrackerTestBackend(transportFactory: { InputTimeoutRequestTransport() })
            let answeredBridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: answeredBackend)
            let answeredModel = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: answeredBridgeClient)
            defer { answeredModel.stop() }
            answeredModel.inputTimeoutCorroborationProbeTimeoutForTesting = .milliseconds(50)
            answeredModel.start()
            await answeredBackend.waitForSubscribeCount(1)
            await answeredModel.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await answeredBackend.setPingOutcome(nil)

            await answeredModel.sendKey("a")

            let answeredProbeRan = await answeredBackend.waitForPingCallCount(1, timeout: .seconds(5))
            XCTAssertTrue(answeredProbeRan, "a bare request timeout must corroborate with a pinned ping")
            try? await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(answeredModel.connectionStage, .connected, "an answered probe must leave the connection alone")
            XCTAssertNil(answeredModel.errorMessage)

            let failedBackend = StageTrackerTestBackend(transportFactory: { InputTimeoutRequestTransport() })
            let failedBridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: failedBackend)
            let failedModel = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: failedBridgeClient)
            defer { failedModel.stop() }
            failedModel.inputTimeoutCorroborationProbeTimeoutForTesting = .milliseconds(50)
            failedModel.connectionBannerGraceSecondsForTesting = 0.05
            failedModel.start()
            await failedBackend.waitForSubscribeCount(1)
            await failedModel.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            await failedBackend.setPingOutcome(SpacesDeviceAPIClientError.requestFailed("ping failed", code: nil))

            await failedModel.sendKey("a")

            let failedProbeRan = await failedBackend.waitForPingCallCount(1, timeout: .seconds(5))
            XCTAssertTrue(failedProbeRan)
            await waitUntil("a failed probe to tear the stream down through the stall path", timeout: .seconds(2)) {
                failedModel.connectionStage == .reconnecting
            }
            XCTAssertNil(failedModel.errorMessage, "a failed probe tears down through the transient path, never errorMessage")
        }

        /// A late probe failure races a stream that has since been replaced: the probe was started
        /// against `probedHandle` (see `startInputTimeoutCorroborationProbe`), but a disconnect it raced
        /// can already have reconnected on its own to a fresh, healthy stream before the ping's answer
        /// comes back. The failure must be checked against the specific stream it was actually asking
        /// about, or it tears down a stream it was never probing.
        func testLateProbeFailureForAReplacedStreamDoesNotTearDownTheNewStream() async throws {
            let backend = StageTrackerTestBackend(transportFactory: { InputTimeoutRequestTransport() })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.inputTimeoutCorroborationProbeTimeoutForTesting = .milliseconds(50)
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            await backend.setHoldNextPing(true)
            await model.sendKey("a")
            let probeStarted = await backend.waitForPingCallCount(1, timeout: .seconds(5))
            XCTAssertTrue(probeStarted, "the request timeout must corroborate with a pinned ping before this test can hold it")

            // Replace the stream the probe was started against while its ping is still in flight, exactly
            // as a disconnect racing the probe would: the old stream drops and a new, healthy one
            // reconnects on its own, all while the held ping is still pending.
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            let reconnected = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(reconnected, "a transient disconnect must redial on its own, independent of the still-pending probe")

            // Now let the stale probe's answer land.
            await backend.releaseHeldPing(with: SpacesDeviceAPIClientError.requestFailed("late ping failure", code: nil))

            let staleProbeTornDownTheNewStream = await backend.waitForSubscribeCount(3, timeout: .milliseconds(500))
            XCTAssertFalse(
                staleProbeTornDownTheNewStream,
                "a late failure for the stream the probe was actually started against must not tear down the stream that replaced it")
        }

        /// A probe task `handleDisconnect` leaves behind when the stream that started it ends must not
        /// survive to block the replacement stream's own corroboration: `startInputTimeoutCorroborationProbe`
        /// is single-flight (`inputTimeoutCorroborationProbeTask != nil`), so a still in-flight probe from
        /// a stream that is already gone would make the replacement stream's own bare request timeout find
        /// the guard already held and never get a ping of its own, and the stale probe's own
        /// `streamHandle === probedHandle` staleness check correctly no-ops on its late answer, so the
        /// replacement's timeout is never reconsidered at all.
        func testStaleProbeFromAReplacedStreamDoesNotBlockANewProbeOnItsReplacement() async throws {
            let backend = StageTrackerTestBackend(transportFactory: { InputTimeoutRequestTransport() })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.inputTimeoutCorroborationProbeTimeoutForTesting = .milliseconds(50)
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            // Start stream A's own corroboration probe and hold its answer, exactly like the late-probe
            // test above, but this time let a replacement stream install without the held ping ever
            // answering, so the stale task is still sitting in `inputTimeoutCorroborationProbeTask` when
            // the replacement gets its own bare timeout.
            await backend.setHoldNextPing(true)
            await model.sendKey("a")
            let probeStarted = await backend.waitForPingCallCount(1, timeout: .seconds(5))
            XCTAssertTrue(probeStarted, "the request timeout must corroborate with a pinned ping before this test can hold it")

            // Disconnect stream A with an error `isTransientReconnectError` does not recognize and that
            // carries no stage-2 evidence: `handleDisconnect`'s `else` branch (see
            // `testTransportClassErrorsRouteOnlyToTheBannerNeverToErrorMessage`) then neither escalates nor
            // calls `registerTransientConnectionLoss()`, so `connectionStage` stays `.connected` straight
            // through the reconnect below. That is what a real stream loss cannot offer here: any path
            // that actually downgrades the stage can only return to `.connected` through `frameReceived()`
            // (see `clearConnectionOutage()`), which already independently cancels a stale probe task on
            // its own: so this is the one disconnect shape that isolates the single-flight bug this test
            // covers from that unrelated self-heal. `shouldReconnectSilently` is true (this client is the
            // owner), so the redial that follows is immediate and does not clear owner input readiness.
            await backend.fireDisconnect(SpacesDeviceAPIClientError.requestFailed("synthetic hard failure for the stale-probe test", code: nil))
            let reconnected = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(reconnected, "a redial must follow even a non-transient disconnect")
            XCTAssertEqual(model.connectionStage, .connected, "a non-transient, non-conclusive disconnect must not move the tracker")

            await waitForRedialBootstrapToLand(model)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 2)

            // The replacement stream's own bare request timeout must be free to start its own probe: before
            // the fix, stream A's still in-flight probe task blocked this outright and `pingCallCount` never
            // moved past 1.
            await model.sendKey("b")
            let secondProbeStarted = await backend.waitForPingCallCount(2, timeout: .seconds(5))
            XCTAssertTrue(
                secondProbeStarted, "the replacement stream's own input timeout must not be blocked by a stale probe from the stream it replaced")

            // Let stream A's stale probe answer land after the fact: it must not tear down the replacement
            // stream it was never actually asking about.
            await backend.releaseHeldPing(with: SpacesDeviceAPIClientError.requestFailed("late ping failure", code: nil))
            try? await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.connectionStage, .connected, "a stale probe answer for the replaced stream must not tear the replacement down")
        }

        /// F2 regression: `allCandidatesUnreachable` on an input send is conclusive stage 2 evidence on
        /// its own, unlike a bare request timeout, so it must not be swallowed as merely transient or
        /// routed through the ping-corroboration probe. It tears the live stream down and escalates
        /// straight to stage 2, with the automatic reconnect armed on `TerminalUnreachableBackoff`'s
        /// ladder. Before `handleInputSendError` intercepted this error ahead of the transient guard, it
        /// fell into `isTransientInputTransportError`'s swallow branch and never moved the tracker at all.
        func testInputSendFailingOnEveryCandidateEscalatesStraightToStage2() async throws {
            let backend = StageTrackerTestBackend(transportFactory: { InputAllCandidatesUnreachableRequestTransport() })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            await model.sendKey("a")

            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }
            XCTAssertTrue(model.isConnectionBannerVisible, "stage 2 shows the banner immediately, with no grace")
            XCTAssertNil(model.errorMessage, "an exhausted-candidates failure is transport-class and must never surface as errorMessage")

            let redialed = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(redialed, "the automatic reconnect must redial on the unreachable ladder")
        }

        /// Mac sibling of the fix above: `DeviceTerminalSessionStateModel.reportFailedInputSend` had a
        /// `guard !isStateStreamDisconnected else { return true }` ahead of its own classification, which
        /// discarded conclusive stage 2 evidence arriving while a reconnect was already armed at stage 1.
        /// `handleInputSendError` on iOS now carries the same gate for a stream that is already gone
        /// (`streamHandle == nil`, `connectionStage != .connected`), with the same stage 1 exception: an
        /// `allCandidatesUnreachable` failure arriving while still at stage 1 is conclusive stage 2
        /// evidence and still escalates. This test covers the case where that gate is not taken: the
        /// automatic redial has already reinstalled a stream (`streamHandle` is non-nil again) by the
        /// time the conclusive input failure arrives, so the teardown path still runs and escalates.
        func testInputSendFailingOnEveryCandidateEscalatesFromStage1EvenWithAReconnectAlreadyArmed() async throws {
            let backend = StageTrackerTestBackend(transportFactory: { InputAllCandidatesUnreachableRequestTransport() })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            // A single, inconclusive stream loss lands at stage 1, the same evidence shape
            // `registerTransientConnectionLoss` records for any ordinary drop.
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach reconnecting", timeout: .seconds(5)) { model.connectionStage == .reconnecting }
            XCTAssertFalse(model.isConnectionBannerVisible, "stage 1 alone must not show the banner")

            // The automatic (silent, owner) redial reinstalls a stream before any input is sent, so the
            // conclusive failure below arrives with a reconnect already in flight rather than with
            // `streamHandle` still nil.
            let redialInstalled = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(redialInstalled, "the automatic redial must have reinstalled a stream before input is sent")
            XCTAssertEqual(model.connectionStage, .reconnecting, "no frame has arrived yet, so the stage must still be stage 1")

            await waitForRedialBootstrapToLand(model)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 2)

            await model.sendKey("a")

            await waitUntil("the stage to escalate to unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }
            XCTAssertTrue(
                model.isConnectionBannerVisible, "conclusive stage 2 evidence must escalate immediately even with a reconnect already armed")
        }

        /// Regression for the ladder re-arm bug: once the link is already reported down (`.unreachable`,
        /// `streamHandle == nil`, a reconnect already armed on the ladder), a repeat `allCandidatesUnreachable`
        /// from a keystroke typed into the outage is only a repeat of evidence the tracker already has, not
        /// new evidence. Before the fix every such keystroke still ran the full teardown path
        /// (`tearDownStream` -> `handleDisconnect` -> `registerUnreachableConnectionAttempt()` ->
        /// `scheduleReconnect`), which advanced the 1/2/4/8/15 s backoff ladder and replaced the pending
        /// timer on every keystroke, so typing while "Device unreachable" was showing kept postponing the
        /// very redial that would recover. This proves the 1 s redial armed when the device first became
        /// unreachable still fires on schedule even while the user keeps typing into the outage.
        func testTypingWhileUnreachableDoesNotPostponeTheAutomaticRedial() async throws {
            let backend = StageTrackerTestBackend(transportFactory: { InputAllCandidatesUnreachableRequestTransport() })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            // The first stream delivered no frame through `onEvent`, so a disconnect with every candidate
            // failed counts as a dial that exhausted every candidate: `handleDisconnect` moves the tracker
            // straight to `.unreachable` and arms the first ladder redial (1 s).
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }

            for key in ["a", "b", "c", "d", "e"] {
                await model.sendKey(key)
                try await Task.sleep(for: .milliseconds(150))
            }

            let redialed = await backend.waitForSubscribeCount(2, timeout: .seconds(3))
            XCTAssertTrue(
                redialed,
                "the 1 s ladder redial armed when the device became unreachable must fire on schedule; typing must not re-arm it further out")
            XCTAssertEqual(model.connectionStage, .unreachable)
        }

        /// Covers a redial that dials successfully (accepted, then closed clean, e.g. a daemon that
        /// accepts a connection and then restarts before subscribing) while the tracker is already
        /// `.unreachable`. `handleDisconnect`'s `error == nil` branch used to fall straight through to
        /// `registerTransientConnectionLoss()` -- a no-op once already `.unreachable` (`streamLost()`
        /// only escalates from `.connected`/`.reconnecting`) -- and then `scheduleReconnect` with the
        /// fixed 150 ms/1 s cadence instead of the stage 2 ladder, dropping the redial pace exactly when
        /// the daemon is proven still unreachable. This proves a clean close in that state keeps the
        /// tracker on the 1/2/4/8/15 s ladder (docs/spec.md:287) instead of reverting to the fast cadence.
        func testACleanCloseWhileUnreachableKeepsTheRedialOnTheLadder() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            // The first stream delivered no frame, so a disconnect with every candidate failed jumps the
            // tracker straight to `.unreachable` and arms the first ladder redial (1 s).
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }

            let redialed = await backend.waitForSubscribeCount(2, timeout: .seconds(3))
            XCTAssertTrue(redialed, "the 1 s ladder redial armed when the device became unreachable must fire on schedule")

            // The redial itself dials and is then closed clean (no error), delivering no frame: exactly
            // the "daemon accepted then restarted" case this test targets. `allStreamCandidatesFailed`
            // does not matter here since `fireDisconnect(nil)` always reports `dialExhaustedAllCandidates:
            // false` regardless of it (see `fireDisconnect`'s doc comment).
            await backend.fireDisconnect(nil)

            // Before the fix this clean close drops back to the 150 ms silent-owner cadence, so a third
            // subscribe would already be in by ~150-300 ms; assert it has NOT happened within 1.2 s.
            let prematureRedial = await backend.waitForSubscribeCount(3, timeout: .milliseconds(1200))
            XCTAssertFalse(prematureRedial, "a clean close while already unreachable must not drop back to the fast owner cadence")
            XCTAssertEqual(model.connectionStage, .unreachable)

            // The ladder's second rung (2 s, armed from the redial above) must still fire on schedule.
            let secondRungRedial = await backend.waitForSubscribeCount(3, timeout: .seconds(2.5))
            XCTAssertTrue(secondRungRedial, "the ladder's next rung must still fire after a clean close while unreachable")
            XCTAssertEqual(model.connectionStage, .unreachable)
            XCTAssertNil(model.errorMessage)
        }

        /// The device comes back, but the terminal it hosted was removed on the daemon in the meantime, so
        /// the redial's subscribe is rejected with "terminal session ... is not available". That verdict is
        /// final: the viewer switches to the unavailable message and nothing it dials can ever change the
        /// answer. Before the fix, only the failing attempt stopped -- the stage 2 tick is armed
        /// independently of any one attempt's outcome, so it kept ticking up the ladder and opening a fresh
        /// subscription on every rung, forever, behind a UI that could never move.
        func testASessionUnavailableRejectionStopsTheUnreachableRedialCadence() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            // The first stream delivered no frame, so a disconnect with every candidate failed jumps the
            // tracker straight to `.unreachable` and arms the first ladder redial (1 s).
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }

            // The device is reachable again by the time that redial goes out, and answers it with the
            // daemon's verdict that this terminal no longer exists.
            await backend.setNextSubscribeError(SpacesDeviceAPIClientError.streamRejected("Terminal session terminal-session is not available."))

            await waitUntil("the rejection to mark the session unavailable", timeout: .seconds(5)) { model.isSessionUnavailable }
            let subscribesAtRejection = await backend.currentSubscribeCount()

            // The ladder's next two rungs (2 s, then 4 s) both come and go inside this window, so a cadence
            // that is still running cannot hide in it.
            let dialedAgain = await backend.waitForSubscribeCount(subscribesAtRejection + 1, timeout: .seconds(6.5))
            XCTAssertFalse(dialedAgain, "a terminal the daemon says no longer exists must not keep being redialed on the stage 2 ladder")
            XCTAssertEqual(model.liveConnectAttemptCountForTesting, 0, "the rejection must retire every attempt, not only the one that failed")
            XCTAssertTrue(model.isSessionUnavailable)
            XCTAssertEqual(model.phase, .unavailable)
        }

        /// Regression for the retry-cancel race described in `retryConnection()`'s own doc comment:
        /// cancelling the handle it drops can deliver its own `onDisconnect(nil)` on the main actor before
        /// `scheduleReconnect` (called later, inside an unstructured `Task`) gets around to bumping
        /// `reconnectAttemptGeneration`. While the generation still matched the cancelled stream's own
        /// connect attempt, that stale clean close reached `handleDisconnect`'s clean-close branch, which
        /// -- while already `.unreachable` -- calls `registerUnreachableConnectionAttempt()` and spends
        /// the ladder rung `connectionStageTracker.retryRequested()` had just reset, so a failed Retry
        /// paced its next attempt at the ladder's second rung (2 s) instead of the promised first rung
        /// (1 s). `retryConnection()` now retires the generation synchronously, before the cancel, so the
        /// cancel's own callback is stale no matter when it actually arrives.
        ///
        /// `StageTrackerTestBackend`'s stream handle does not itself invoke `onDisconnect` on `cancel()`
        /// (its cancel handler only records a call for `waitForCancelCount`; see
        /// `SpacesDeviceAPIStreamHandle.cancel()`), so this drives the same ordering explicitly: it fires
        /// the redial's own clean close directly, right after `retryConnection()` returns, standing in for
        /// a same-turn `onDisconnect(nil)` a real cancel can trigger.
        func testRetryDoesNotLetTheCancelledStreamsCloseSpendTheResetRung() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            // The first stream delivers no frame, so a disconnect with every candidate failed jumps the
            // tracker straight to `.unreachable` and arms the first ladder redial (1 s).
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }

            // That redial dials and installs a stream handle while delivering no frame yet -- exactly the
            // shape `retryConnection()`'s doc comment describes -- which is the handle Retry below cancels.
            let redialed = await backend.waitForSubscribeCount(2, timeout: .seconds(3))
            XCTAssertTrue(redialed, "the 1 s ladder redial armed when the device became unreachable must fire on schedule")

            model.retryConnection()
            // Reproduces the cancelled stream's own clean close arriving around the same time as the
            // cancel, standing in for what `StageTrackerTestBackend`'s fake handle does not deliver itself.
            await backend.fireDisconnect(nil)

            // Retry's own redial dials immediately and also fails, with every candidate exhausted and no
            // frame delivered: conclusive stage 2 evidence for this attempt.
            let retried = await backend.waitForSubscribeCount(3, timeout: .seconds(3))
            XCTAssertTrue(retried, "retryConnection() must redial immediately")
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)

            await waitUntil("the stage to read unreachable after the failed retry", timeout: .seconds(5)) { model.connectionStage == .unreachable }
            XCTAssertEqual(
                model.lastScheduledReconnectDelayForTesting, .seconds(1),
                "a failed Retry must pace its next attempt at the ladder's first rung, not the second: the reset rung must not have been spent by the cancelled stream's stale clean close"
            )
        }

        /// Sibling of `testTypingWhileUnreachableDoesNotPostponeTheAutomaticRedial`, covering the case that
        /// test cannot reach: `connect()` installs `streamHandle` as soon as `subscribe` returns, which is
        /// before the underlying dial completes and long before any frame arrives, so once the 1 s ladder
        /// redial fires (`waitForSubscribeCount(2)` below), `streamHandle` is non-nil again while the stage
        /// is still `.unreachable` -- the redial is in flight but has not yet proven the link recovered.
        /// Before the fix, `handleInputSendError`'s gate read `streamHandle == nil`, so it was skipped once
        /// that handle existed: a keystroke's connection-level failure fell to the bare connection-level
        /// branch, which tore the just-redialed stream down through `tearDownStream(reportingLoss:)`.
        /// Gating on the tracker's stage alone (this fix) recognizes the in-flight redial as still "link
        /// already reported down" and drops the keystroke without touching it, so the redial that already
        /// fired keeps running. The assertion is on the redial's stream handle never being cancelled
        /// rather than on a subscribe count: the stage 2 ladder is a redial cadence that dials again on
        /// its own schedule whatever the user types, so a count only says nothing extra happened before
        /// the cadence's next tick, while the cancel says the in-flight dial itself was left alone.
        func testTypingDuringAnInFlightUnreachableRedialDoesNotAbortIt() async throws {
            let backend = StageTrackerTestBackend(transportFactory: { InputConnectionResetRequestTransport() })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            // Same path to stage 2 as the sibling test above: a stream that delivered no frame, disconnected
            // with every candidate failed, jumps straight to `.unreachable` and arms the first ladder redial.
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }

            // Wait for the 1 s ladder redial to fire and install a fresh `streamHandle`. This second stream
            // also delivers no frame, so the stage stays `.unreachable` even though a handle now exists --
            // exactly the "handle installed, link not yet proven" window this test is targeting.
            let redialInstalled = await backend.waitForSubscribeCount(2, timeout: .seconds(3))
            XCTAssertTrue(redialInstalled, "the 1 s ladder redial must fire and install a stream before input is sent")
            XCTAssertEqual(
                model.connectionStage, .unreachable, "the redialed stream has delivered no frame, so the stage must still read unreachable")

            // The redial's own bootstrap `.state` read (see `waitForRedialBootstrapToLand`) answers with an
            // ownerless snapshot that clears ownership once it lands; `sendKey` below silently no-ops
            // without it, which would pass this test for the wrong reason (no send ever reaches
            // `handleInputSendError` either before or after the fix). Wait for it, then reassert ownership,
            // exactly like `testInputSendFailingOnEveryCandidateEscalatesFromStage1EvenWithAReconnectAlreadyArmed`.
            await waitForRedialBootstrapToLand(model)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 2)

            for key in ["a", "b", "c", "d", "e"] {
                await model.sendKey(key)
                try await Task.sleep(for: .milliseconds(150))
            }

            // Give the old, buggy path time to run its course: it tore the redialed stream down, which
            // cancels its handle. The window stays short of the ladder's next rung (2 s from the redial),
            // so the cadence's own next dial has not fired yet and the subscribe count still reads the
            // redial alone.
            try await Task.sleep(for: .milliseconds(400))
            let cancelCount = await backend.currentCancelCount()
            XCTAssertEqual(cancelCount, 0, "typing into an in-flight redial must not tear its stream down")
            let finalSubscribeCount = await backend.currentSubscribeCount()
            XCTAssertEqual(finalSubscribeCount, 2, "no redial beyond the one the ladder already made: the next rung has not elapsed yet")
            XCTAssertEqual(model.connectionStage, .unreachable)
            XCTAssertNil(model.errorMessage)
        }

        /// The stage 2 ladder is a redial cadence, not a per-failure delay: when a rung elapses with an
        /// attempt still in flight, a fresh dial starts alongside the stale one instead of waiting for it
        /// to give up. That is the point of the fix for #676 -- the attempt that is hanging on an address
        /// that was dead when it started is exactly the one that cannot notice the link coming back, so
        /// waiting for its transport budget made a phone that regained its link take a fixed ten seconds
        /// to paint. Whichever dial delivers a frame first wins, the older one included, and from that
        /// instant the loser is cancelled and everything it still has in flight is ignored.
        func testAnUnreachableLadderTickRacesAFreshDialAndTheFirstFrameWins() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }

            // The ladder's first rung (1 s) dials stream 2, and nothing in this test ever answers it: it
            // stands in for the dial still hanging on an address that was down when it started.
            let firstRungDial = await backend.waitForSubscribeCount(2, timeout: .seconds(3))
            XCTAssertTrue(firstRungDial, "the ladder's first rung must dial")

            // The second rung (2 s) must dial again even though stream 2 has neither failed nor answered.
            let secondRungDial = await backend.waitForSubscribeCount(3, timeout: .seconds(4))
            XCTAssertTrue(secondRungDial, "the next rung must start a fresh dial while the previous attempt is still in flight")
            let cancelsDuringTheRace = await backend.currentCancelCount()
            XCTAssertEqual(cancelsDuringTheRace, 0, "the in-flight attempt must be raced, not superseded and cancelled")

            // The stale dial is the one that reaches the device, which is the case the fix exists for.
            await backend.fireFrame(Self.outputState(title: "stale-wins", emittedAt: "2026-06-04T14:23:40Z"), onStream: 2)
            await waitUntil("the stage to return to connected") { model.connectionStage == .connected }
            XCTAssertFalse(model.isConnectionBannerVisible, "the winning frame must clear the banner")
            await waitUntil("the winner's frame to be applied") { model.latestState?.title == "stale-wins" }
            let loserCancelled = await backend.waitForCancelCount(1, timeout: .seconds(2))
            XCTAssertTrue(loserCancelled, "the losing dial's stream must be cancelled the moment the winner delivers a frame")

            // The loser is inert from here: its payloads must not reach the reduction pipeline (its
            // `emittedAt` is newer, so one that did would replace what the winner painted), and its
            // failure must neither flip the stage back nor redial.
            await backend.fireFrame(Self.outputState(title: "loser", emittedAt: "2026-06-04T14:23:50Z"), onStream: 3)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled, onStream: 3)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(model.latestState?.title, "stale-wins", "a losing attempt's payload must never reach the reduction pipeline")
            XCTAssertEqual(model.connectionStage, .connected, "a losing attempt's failure must not flip the stage back")
            let subscribesAfterTheRace = await backend.currentSubscribeCount()
            XCTAssertEqual(subscribesAfterTheRace, 3, "a losing attempt's failure must not schedule a redial of its own")
        }

        /// The race is capped at two dials: the stale one and the fresh one. A third tick against a
        /// device that is still not answering retires the oldest rather than letting dead dials pile up,
        /// and `SpacesDeviceAPIStreamHandle` has no deinit cancellation, so the retired one's connection
        /// has to be cancelled explicitly. The attempt that survives the cap can still win.
        func testAThirdUnreachableTickRetiresTheOldestLiveDial() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }

            // Rungs 1, 2 and 4 dial streams 2, 3 and 4; none of them ever answers.
            let firstTwoRungsDialed = await backend.waitForSubscribeCount(3, timeout: .seconds(6))
            XCTAssertTrue(firstTwoRungsDialed, "the first two rungs must dial")
            let cancelsWithTwoLive = await backend.currentCancelCount()
            XCTAssertEqual(cancelsWithTwoLive, 0, "two live dials are within the cap, so neither is retired")

            let thirdRungDialed = await backend.waitForSubscribeCount(4, timeout: .seconds(7))
            XCTAssertTrue(thirdRungDialed, "the third rung must dial")
            let cancelsAfterTheCap = await backend.waitForCancelCount(1, timeout: .seconds(2))
            XCTAssertTrue(cancelsAfterTheCap, "the third dial must retire the oldest of the two already live")
            let cancelsAfterSettling = await backend.currentCancelCount()
            XCTAssertEqual(cancelsAfterSettling, 1, "only the oldest dial is retired, not both of the ones already live")

            // The retired dial is inert; the one that survived the cap is still racing and can still win.
            await backend.fireFrame(Self.outputState(title: "retired", emittedAt: "2026-06-04T14:23:41Z"), onStream: 2)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(model.connectionStage, .unreachable, "a retired dial's frame proves nothing about the connection")

            await backend.fireFrame(Self.outputState(title: "survivor-wins", emittedAt: "2026-06-04T14:23:42Z"), onStream: 3)
            await waitUntil("the stage to return to connected") { model.connectionStage == .connected }
            await waitUntil("the surviving dial's frame to be applied") { model.latestState?.title == "survivor-wins" }
        }

        /// Every live dial has to go when the viewer does. Two are live here, and a stopped viewer must
        /// leave neither the connections nor the redial cadence running behind it.
        func testStoppingWhileTwoUnreachableDialsAreLiveCancelsBoth() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }
            let twoDialsLive = await backend.waitForSubscribeCount(3, timeout: .seconds(6))
            XCTAssertTrue(twoDialsLive, "two dials must be live before the stop")

            model.stop()

            let bothCancelled = await backend.waitForCancelCount(2, timeout: .seconds(2))
            XCTAssertTrue(bothCancelled, "a stop must cancel every dial still in flight, not just the newest")
            try await Task.sleep(for: .seconds(1.5))
            let subscribesAfterStop = await backend.currentSubscribeCount()
            XCTAssertEqual(subscribesAfterStop, 3, "a stopped viewer must not keep the redial cadence running")
        }

        /// The ladder advances once per redial tick, never once per failed attempt: with two dials racing,
        /// pacing on failures would spend rungs at whatever rate the failures happened to arrive and would
        /// re-arm the pending redial each time, pushing recovery out exactly when the device is proven
        /// down. A losing dial's failure must leave the tick that is already armed exactly as it is.
        func testALosingUnreachableDialsFailureSpendsNoLadderRung() async throws {
            let backend = StageTrackerTestBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }

            // Rungs 1 and 2 dial streams 2 and 3; the tick armed after stream 3 is the ladder's third rung.
            let rungsDialed = await backend.waitForSubscribeCount(3, timeout: .seconds(6))
            XCTAssertTrue(rungsDialed, "the first two rungs must dial")
            await waitUntil("the third rung to be armed") { model.lastScheduledReconnectDelayForTesting == .seconds(4) }

            // The stale dial now fails on its own. Under a per-failure ladder this spends the next rung
            // (8 s) and re-arms the pending redial from scratch.
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled, onStream: 2)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(
                model.lastScheduledReconnectDelayForTesting, .seconds(4),
                "an attempt ending is not a ladder tick, so it must neither spend a rung nor re-arm the pending redial")
            XCTAssertEqual(model.connectionStage, .unreachable)
            let prematureRedial = await backend.waitForSubscribeCount(4, timeout: .seconds(2))
            XCTAssertFalse(prematureRedial, "the tick armed before the failure must keep its own schedule")
        }

        /// A losing stage 2 dial's failure handler suspends inside its ended-state recovery read, and the
        /// racing dial's winning frame lands while it is parked. The handler must not resume into the
        /// rest of the failure path: `scheduleReconnect` cancels every live attempt, so the very stream
        /// that just recovered the viewer would be torn down and redialed from scratch, throwing away the
        /// recovery this concurrent-redial design exists to make fast (#676).
        func testAFrameWinningDuringALosingDialsRecoveryReadKeepsTheWinningStream() async throws {
            let transport = HeldStateReadRequestTransport()
            let backend = StageTrackerTestBackend(transportFactory: { transport })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }

            // Rungs 1 and 2 dial streams 2 and 3, so two attempts are racing. The tick armed after stream
            // 3 is four seconds out, which is the quiet window everything below runs in.
            let bothDialsRacing = await backend.waitForSubscribeCount(3, timeout: .seconds(6))
            XCTAssertTrue(bothDialsRacing, "two dials must be racing before the recovery read is held")
            await waitUntil("the next rung to be armed") { model.lastScheduledReconnectDelayForTesting == .seconds(4) }

            // The older dial now ends with the daemon's missing-live-stream error, the one failure whose
            // handling suspends in a state read. Holding that read is what puts the winning frame below
            // squarely inside the handler's own suspension.
            await transport.armStateReadHold()
            await backend.fireDisconnect(
                SpacesDeviceAPIClientError.streamFailed("Terminal session 'terminal-session' has no live state stream."), onStream: 2)
            let recoveryReadHeld = await transport.waitForHeldStateRead()
            XCTAssertTrue(recoveryReadHeld, "the losing dial's failure must suspend in its ended-state recovery read")

            // The racing dial reaches the device while that handler is parked: it wins the race, and from
            // here the viewer is connected on stream 3.
            await backend.fireFrame(Self.outputState(title: "winner", emittedAt: "2026-06-04T14:23:40Z"), onStream: 3)
            await waitUntil("the stage to return to connected") { model.connectionStage == .connected }
            await waitUntil("the winner's frame to be applied") { model.latestState?.title == "winner" }

            // The held read answers with a live session, so the recovery recovers nothing and the
            // overtaken handler resumes into the rest of the failure path.
            await transport.releaseHeldStateRead()

            let staleTeardown = await backend.waitForCancelCount(1, timeout: .seconds(1))
            XCTAssertFalse(staleTeardown, "an overtaken failure must not cancel the stream that won the race")
            try await Task.sleep(for: .seconds(1))
            let subscribesAfterTheRecovery = await backend.currentSubscribeCount()
            XCTAssertEqual(subscribesAfterTheRecovery, 3, "an overtaken failure must not redial over a connection that is already up")
            XCTAssertEqual(model.connectionStage, .connected, "an overtaken failure must not move the viewer off its winning stream")
        }

        /// The connect-error sibling of the test above: here the losing stage 2 attempt never opens a
        /// stream at all -- its subscribe is refused with the same missing-live-stream error -- so the
        /// suspension happens in `handleConnectError`'s recovery read instead. The attempt that is still
        /// live wins while it is parked, and must survive the same way.
        func testAFrameWinningDuringARefusedDialsRecoveryReadKeepsTheWinningStream() async throws {
            let transport = HeldStateReadRequestTransport()
            let backend = StageTrackerTestBackend(transportFactory: { transport })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }

            // Rung 1 dials stream 2 and nothing answers it yet; that dial is the one that will win. Rung 2
            // is refused outright, so it opens no stream of its own and goes straight to
            // `handleConnectError`.
            let firstRungDialed = await backend.waitForSubscribeCount(2, timeout: .seconds(4))
            XCTAssertTrue(firstRungDialed, "the ladder's first rung must dial")
            await backend.setNextSubscribeError(SpacesDeviceAPIClientError.requestFailed("no live state stream", code: nil))
            await transport.armStateReadHold()

            let secondRungRefused = await backend.waitForSubscribeCount(3, timeout: .seconds(5))
            XCTAssertTrue(secondRungRefused, "the next rung must dial and be refused")
            let recoveryReadHeld = await transport.waitForHeldStateRead()
            XCTAssertTrue(recoveryReadHeld, "the refused dial's failure must suspend in its ended-state recovery read")

            await backend.fireFrame(Self.outputState(title: "winner", emittedAt: "2026-06-04T14:23:40Z"), onStream: 2)
            await waitUntil("the stage to return to connected") { model.connectionStage == .connected }
            await waitUntil("the winner's frame to be applied") { model.latestState?.title == "winner" }

            await transport.releaseHeldStateRead()

            let staleTeardown = await backend.waitForCancelCount(1, timeout: .seconds(1))
            XCTAssertFalse(staleTeardown, "an overtaken connect failure must not cancel the stream that won the race")
            try await Task.sleep(for: .seconds(1))
            let subscribesAfterTheRecovery = await backend.currentSubscribeCount()
            XCTAssertEqual(subscribesAfterTheRecovery, 3, "an overtaken connect failure must not redial over a connection that is already up")
            XCTAssertEqual(model.connectionStage, .connected, "an overtaken connect failure must not move the viewer off its winning stream")
        }

        /// A redial made while the device is already reported unreachable dials on a much shorter budget
        /// than the first connection an open makes: its job is to notice the device coming back, and the
        /// tick starts a fresh dial regardless, so a dead dial only has to be gone before it costs a
        /// concurrency slot. A cold open has no such backstop and keeps the full budget.
        func testARedialIntoAnOutageDialsOnAShorterBudgetThanAColdOpen() async throws {
            let transport = StateTimeoutRecordingRequestTransport()
            let backend = StageTrackerTestBackend(transportFactory: { transport })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)
            // Read budgets are matched by value, not by position: this viewer issues `.state` reads for
            // several reasons (the automatic takeover's confirmation read among them), and only the
            // connect bootstrap's budget is what this test is about. They are also compared as bounds
            // rather than for equality, since the command channel hands the transport whatever is left of
            // the caller's budget after waiting its turn on the channel.
            await waitUntilAsync("the cold open's bootstrap read to be issued") {
                await transport.stateRequestTimeouts().contains { $0 > .seconds(11) }
            }
            let coldOpenBudgets = await backend.initialEventTimeouts
            XCTAssertEqual(coldOpenBudgets.first, .seconds(12), "a cold open dials on the full initial-event budget")
            let coldOpenReads = await transport.stateRequestTimeouts()
            XCTAssertFalse(coldOpenReads.contains { $0 <= .seconds(4) }, "no read a cold open makes is cut to the reconnect budget")
            let coldOpenReadCount = coldOpenReads.count

            await backend.setAllStreamCandidatesFailed(true)
            await backend.fireDisconnect(SpacesDeviceAPIClientError.streamStalled)
            await waitUntil("the stage to reach unreachable", timeout: .seconds(5)) { model.connectionStage == .unreachable }
            let firstRungDialed = await backend.waitForSubscribeCount(2, timeout: .seconds(3))
            XCTAssertTrue(firstRungDialed, "the ladder's first rung must dial")
            await waitUntilAsync("the redial's bootstrap read to be issued") {
                await transport.stateRequestTimeouts().dropFirst(coldOpenReadCount).contains { $0 <= .seconds(4) }
            }

            let budgets = await backend.initialEventTimeouts
            XCTAssertEqual(budgets.count, 2)
            XCTAssertEqual(budgets[1], .seconds(4), "a redial into a reported outage dials on the short initial-event budget")
            let redialReads = Array(await transport.stateRequestTimeouts().dropFirst(coldOpenReadCount))
            XCTAssertTrue(
                redialReads.contains { $0 > .seconds(3) && $0 <= .seconds(4) },
                "the redial's bootstrap read is cut to the reconnect budget, and still keeps a usable one")
        }

        /// `TerminalScrollCoalescer` allows only one in-flight batch at a time (`queuedBatchCount`),
        /// releasing that slot from `onFinished`, which `enqueueCoalescedScrollBatch` fires when its
        /// queued send completes. A batch that never runs because `cancelQueuedInputSends()`
        /// (`inputSendQueue.cancelAll()`) discarded it while still queued behind an earlier, failed key
        /// send used to never call `onFinished` at all, so `queuedBatchCount` stayed stuck above zero and
        /// every later `append` -- which only schedules a flush when `queuedBatchCount == 0` -- silently
        /// piled into `pending` forever. `TerminalInputSerialQueue.enqueue`'s `onDiscarded` parameter is
        /// the fix: it fires exactly once for a task discarded before `operation` ever ran, and
        /// `enqueueCoalescedScrollBatch` wires it to the same `onFinished` the operation itself would have
        /// called, so the coalescer's slot is released either way.
        func testAScrollBatchDroppedWithTheInputBacklogDoesNotWedgeLaterScrolling() async throws {
            let tracker = ScrollAfterKeyFailureTracker()
            let backend = StageTrackerTestBackend(transportFactory: { ScrollAfterKeyFailureRequestTransport(tracker: tracker) })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            // The key send fails on both its immediate attempt and `performRequestUsingInputChannel`'s
            // 120 ms retry (see `ScrollAfterKeyFailureRequestTransport`), so it reaches
            // `handleInputSendError` as connection-level evidence and escalates through
            // `tearDownStream(reportingLoss:)` + `cancelQueuedInputSends()`. The scroll sent right behind
            // it never calls `flushPendingScroll()` (only `sendKey` does that): it relies on
            // `TerminalScrollCoalescer`'s own automatic frame-interval flush, which chains the batch onto
            // the input queue a few milliseconds later, behind the still-running key send, so it is still
            // queued (not yet run) when the key's failure discards it.
            await model.sendKey("a")
            await model.sendScroll(horizontal: 0, vertical: 5, scrollMods: 0, pointerPosition: nil)

            // Give the key send's synchronous attempt, its 120 ms retry, and the failure handling that
            // follows time to run to completion and discard the queued scroll batch.
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(
                tracker.currentScrollRequestCount(), 0, "the scroll batch queued behind the failed key send must never reach the transport")

            // The escalation above tears the stream down and arms a redial; wait for its bootstrap read to
            // land and reassert ownership before sending again, exactly like
            // `testTypingDuringAnInFlightUnreachableRedialDoesNotAbortIt` above: otherwise this second
            // `sendScroll` call's own `guard isOwner` would silently no-op it for the wrong reason, and the
            // assertion below would pass without ever exercising the coalescer.
            await waitForRedialBootstrapToLand(model)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 2)

            await model.sendScroll(horizontal: 0, vertical: 7, scrollMods: 0, pointerPosition: nil)
            await waitUntil("the post-recovery scroll to reach the transport", timeout: .seconds(3)) { tracker.currentScrollRequestCount() == 1 }
        }

        /// K1 regression: a connection-level transport failure on an input send (a reset, refused, or
        /// aborted socket, not a bare client-deadline timeout) is conclusive evidence the link itself is
        /// down, the same way Mac's `DeviceTerminalSessionStateModel.reportFailedInputSend` classifies it
        /// via `isTransportFailureEvidenceOfLostLink`. Before the fix, `handleInputSendError`'s guard
        /// classified this shape as merely `isTransientInputTransportError` and, since it is not the
        /// narrower `.requestTimedOut` case that starts the corroboration probe, silently swallowed it:
        /// the model never reacted at all and the stream stayed apparently open until its own 8 s silence
        /// watchdog eventually noticed independently. This proves the model instead tears the stream down
        /// immediately as stage 1 evidence, reaching `.reconnecting`, never `.unreachable`, since
        /// `allCandidatesUnreachable` stays the only stage 2 evidence, and redials.
        func testInputSendFailingWithAConnectionResetTearsTheStreamDownAsStage1Evidence() async throws {
            let backend = StageTrackerTestBackend(transportFactory: { InputConnectionResetRequestTransport() })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            await model.sendKey("a")

            await waitUntil("the stage to reach reconnecting", timeout: .seconds(5)) { model.connectionStage == .reconnecting }
            XCTAssertNotEqual(
                model.connectionStage, .unreachable,
                "a connection-level input failure is stage 1 evidence only; allCandidatesUnreachable stays the only stage 2 evidence")
            XCTAssertNil(model.errorMessage, "a connection-level transport failure is banner evidence, not a red errorMessage")

            let redialed = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(redialed, "the automatic reconnect must redial after the stream tears down")
        }

        /// A lost route (`EHOSTUNREACH` here; `EHOSTDOWN`, `ENETDOWN`, `ENETUNREACH` are the same class)
        /// is the shape an established connection reports when the Wi-Fi radio drops or a tailnet route
        /// is withdrawn. It is connection-level evidence exactly like a reset, and the stream classifier
        /// (`isStreamHostTransportFailure`) already reads it that way; before the fix the input-path
        /// classifiers did not, so the send fell through to a red `errorMessage` and the stale stream was
        /// left standing.
        func testInputSendFailingWithARouteLossTearsTheStreamDownAsStage1Evidence() async throws {
            let backend = StageTrackerTestBackend(transportFactory: { InputRouteLossRequestTransport() })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            await model.sendKey("a")

            await waitUntil("the stage to reach reconnecting", timeout: .seconds(5)) { model.connectionStage == .reconnecting }
            XCTAssertNil(model.errorMessage, "a lost route is banner evidence, not a red errorMessage")
            let redialed = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(redialed, "the automatic reconnect must redial after the stream tears down")
        }

        /// A daemon-busy rejection ("Timed out waiting for the terminal to accept the send.") is a decoded
        /// `SpacesDeviceAPIClientError.requestFailed` answer, not a transport-level timeout: the daemon was
        /// reachable enough to decode the request and answer it. Before the fix,
        /// `isConnectionLevelInputTransportError` substring-matched "timed out" in the message and treated
        /// this the same as a real connection timeout, tearing down a healthy stream and forcing a redial.
        /// The rejection still gets swallowed as transient (no red `errorMessage`) by
        /// `isTransientInputTransportError`, exactly as before this fix; only the stream teardown is wrong.
        func testADaemonTimeoutRejectionOfAnInputSendLeavesTheStreamAlone() async throws {
            let backend = StageTrackerTestBackend(transportFactory: { InputDaemonTimeoutRejectionRequestTransport() })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            await model.sendKey("a")

            // A bounded wait for a second subscribe that must NOT happen: if the stream were torn down,
            // the automatic reconnect would redial well within this window. Returning false is the proof
            // that no redial occurred, not merely that we stopped waiting for one.
            let redialed = await backend.waitForSubscribeCount(2, timeout: .seconds(1))
            XCTAssertFalse(redialed, "a decoded daemon rejection is not link loss; the healthy stream must not be torn down")
            XCTAssertEqual(model.connectionStage, .connected)
            XCTAssertNil(model.errorMessage, "the daemon-busy rejection is swallowed as transient, same as before this fix")
        }

        /// A peer that closes the command connection before answering (EOF, no bytes decoded) is
        /// `SpacesDeviceAPIClientError.connectionClosed`, not a decoded daemon rejection: the daemon never
        /// had a chance to say no. Guards against the shape being folded back into `.requestFailed`,
        /// which `isConnectionLevelInputTransportError` deliberately excludes as a decoded answer: on
        /// that read the send is swallowed as merely transient and the dead stream is left standing
        /// until the 8 s watchdog notices on its own.
        /// This proves the fix instead tears the stream down as stage 1 evidence, exactly like a reset.
        func testAPeerClosingTheCommandConnectionUnderAnInputSendTearsTheStreamDown() async throws {
            let backend = StageTrackerTestBackend(transportFactory: { InputConnectionClosedRequestTransport() })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            await model.sendKey("a")

            await waitUntil("the stage to reach reconnecting", timeout: .seconds(5)) { model.connectionStage == .reconnecting }
            XCTAssertNil(model.errorMessage, "a peer-closed command connection is banner evidence, not a red errorMessage")

            let redialed = await backend.waitForSubscribeCount(2, timeout: .seconds(3))
            XCTAssertTrue(redialed, "the automatic reconnect must redial after the stream tears down")
        }

        /// The stream-side sibling: a stream that ends with a lost-route error while a frame is still on
        /// screen reconnects silently, the same as a reset or a stall, instead of surfacing the raw
        /// POSIX text as an error.
        func testAStreamEndingWithARouteLossReconnectsSilently() async throws {
            let backend = StalledStreamBackend()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.applyLatestState(
                Self.runningTerminalState(attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:30Z"),
                isOutOfBand: false)

            model.start()
            await backend.waitForSubscribeCount(1)

            await backend.reportDisconnect(POSIXError(.ENETUNREACH))

            let resubscribed = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(resubscribed, "a lost route is recovered by opening a new stream")
            XCTAssertNil(model.errorMessage, "a lost route with a frame still on screen must reconnect silently")
            XCTAssertEqual(model.connectionStage, .reconnecting)
        }

        /// A daemon restart wipes every `terminal_clients`/`terminal_attachments` row, so a client that
        /// held an attachment before a reconnect and whose bootstrap snapshot no longer names it must
        /// re-attach on its own. Without this, the stream keeps delivering frames (the pane looks alive)
        /// while every input the client sends is rejected, because the daemon holds no attachment for it
        /// at all. Mirrors the Mac pane's `refreshNow` (`TerminalSessionPaneViewController.swift`,
        /// `attachmentModeToRequest`), which re-attaches under the identical condition.
        ///
        /// Backgrounded throughout (`prepareForBackgrounding()`, never resumed): a running session this
        /// client does not own also arms the pre-existing, unrelated "claim an ownerless session"
        /// automatic takeover (`attemptAutomaticTakeoverIfNeeded`, gated on `isSceneActive`) on every
        /// applied state, including a plain viewer's very first bootstrap. Backgrounding is this suite's
        /// established way of holding that mechanism off (see `testInitiallyInactiveViewerWaitsForActivationBeforeAutomaticTakeover`),
        /// which is what isolates the reattach behavior this test actually protects.
        func testAViewerWhoseAttachmentVanishedAcrossAReconnectAttachesAgain() async throws {
            let backend = RestartedDaemonBackend(attachmentSnapshot: TerminalSessionAttachmentSnapshot())
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.prepareForBackgrounding()

            let client = model.remoteClientForTesting
            let viewerAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:23:30Z")
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot(clients: [client], attachments: [viewerAttachment]))

            model.start()
            _ = await backend.waitForSubscribeCount(1)
            _ = await backend.waitForAttachCount(1)
            await waitUntil("the bootstrap attachment to land") {
                model.attachmentSnapshot.attachments.contains { $0.clientID == client.id && $0.detachedAt == nil }
            }

            // The daemon restarts: its next answer names nobody attached at all.
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot())
            await backend.reportDisconnect(POSIXError(.ECONNRESET))

            let resubscribed = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(resubscribed, "a reset stream must reconnect")
            let reattached = await backend.waitForAttachCount(2, timeout: .seconds(5))
            XCTAssertTrue(reattached, "the reconnect's empty bootstrap snapshot must trigger a reattach")

            let takeoverCount = await backend.currentTakeoverCount()
            XCTAssertEqual(takeoverCount, 0, "a former viewer reattaching must not take over")
            let mode = await backend.lastAttachedMode()
            XCTAssertEqual(mode, .viewer, "the reattach must stay a viewer attach, matching what this client was before the restart")
        }

        /// The sibling of the reattach case above: a reconnect whose bootstrap snapshot still names this
        /// client (a network blip, the daemon's rows intact) must send nothing. This client could be the
        /// session's owner, and the only mode `attachViewerForCurrentLifecycle` sends is `.viewer`, so a
        /// blind reattach here would demote an owner for no reason.
        ///
        /// Backgrounded throughout for the same reason as the reattach test above: it keeps the
        /// pre-existing "claim an ownerless session" automatic takeover from firing on this viewer's own
        /// bootstrap, isolating the "does not attach again" behavior this test actually protects.
        func testAReconnectWhoseBootstrapStillNamesThisClientDoesNotAttachAgain() async throws {
            let backend = RestartedDaemonBackend(attachmentSnapshot: TerminalSessionAttachmentSnapshot())
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.prepareForBackgrounding()

            let client = model.remoteClientForTesting
            let viewerAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:23:30Z")
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot(clients: [client], attachments: [viewerAttachment]))

            model.start()
            _ = await backend.waitForSubscribeCount(1)
            _ = await backend.waitForAttachCount(1)
            await waitUntil("the bootstrap attachment to land") {
                model.attachmentSnapshot.attachments.contains { $0.clientID == client.id && $0.detachedAt == nil }
            }

            // The daemon's rows survive this disconnect: the next bootstrap still names this client.
            await backend.reportDisconnect(POSIXError(.ECONNRESET))
            let resubscribed = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(resubscribed, "a reset stream must reconnect")
            let secondStateRead = await backend.waitForStateReadCount(2, timeout: .seconds(5))
            XCTAssertTrue(secondStateRead, "the reconnect's bootstrap read must land")

            // Nothing distinguishes "will never attach again" from "hasn't attached again yet" here, so
            // give the model a beat past the bootstrap landing before asserting the negative.
            try? await Task.sleep(for: .milliseconds(300))

            let attachCount = await backend.currentAttachCount()
            XCTAssertEqual(attachCount, 1, "a reconnect whose snapshot still names this client must not attach again")
            let takeoverCount = await backend.currentTakeoverCount()
            XCTAssertEqual(takeoverCount, 0)
        }

        /// A former owner whose attachment vanished across a reconnect hands itself back its one
        /// automatic takeover, so it reclaims the session it owned instead of leaving it ownerless until
        /// some other client happens to take over. The Mac pane does the equivalent by re-attaching
        /// directly as owner; this client re-attaches as viewer first (`attachViewerForCurrentLifecycle`
        /// has no owner mode) and then takes over.
        ///
        /// The scene stays active (unlike the two tests above): this is the one case where the automatic
        /// takeover actually must fire, since `attemptAutomaticTakeoverIfNeeded` requires `isSceneActive`.
        /// That leaves the pre-existing "claim an ownerless session" mechanism free to also fire on this
        /// same reconnect's bootstrap, racing the production reattach this test protects — `attachIndex <
        /// takeoverIndex` holds regardless of how that race resolves only because `RestartedDaemonBackend`
        /// rejects a takeover from a client it has no attachment for: the accepted takeover can only be
        /// the one this client's own reattach made legitimate.
        ///
        /// Ownership is seeded with `configureOwnerInteractiveForTesting`, not a pre-set
        /// `RestartedDaemonBackend` snapshot alone: `connect()`'s own `shouldAttachBeforeSubscribing`
        /// sends a blind `.viewer` attach ahead of the very first bootstrap whenever `hasAttachedToSession`
        /// is still false, which — now that this backend's `.attach` registers whatever mode it is sent —
        /// would demote a merely-seeded owner before the bootstrap ever confirms it. Seeding through
        /// `configureOwnerInteractiveForTesting` sets `hasAttachedToSession` (and `isOwner`) the same way
        /// a real prior attach would have, so that blind pre-attach never fires, exactly as it would not
        /// for a genuine already-attached owner reconnecting.
        func testAFormerOwnerReclaimsTheSessionAfterItsAttachmentVanished() async throws {
            let backend = RestartedDaemonBackend(attachmentSnapshot: TerminalSessionAttachmentSnapshot())
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            let client = model.remoteClientForTesting
            let ownerAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: client.id, mode: .owner, attachedAt: "2026-06-04T14:23:30Z")
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot(clients: [client], attachments: [ownerAttachment]))

            model.start()
            _ = await backend.waitForSubscribeCount(1)
            await waitUntil("the bootstrap owner snapshot to apply", timeout: .seconds(5)) { model.isOwner }

            let takeoverCountBeforeRestart = await backend.currentTakeoverCount()
            XCTAssertEqual(takeoverCountBeforeRestart, 0, "confirming ownership from the bootstrap must not itself take over")
            let attachCountBeforeRestart = await backend.currentAttachCount()
            XCTAssertEqual(attachCountBeforeRestart, 0, "an already-attached owner's first connect must send no attach at all")

            // The daemon restarts: its next answer names nobody attached at all.
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot())
            await backend.reportDisconnect(POSIXError(.ECONNRESET))

            let resubscribed = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(resubscribed, "a reset stream must reconnect")
            let reattached = await backend.waitForAttachCount(1, timeout: .seconds(5))
            XCTAssertTrue(reattached, "the former owner must reattach once its attachment is gone")
            let tookOver = await backend.waitForTakeoverCount(1, timeout: .seconds(5))
            XCTAssertTrue(tookOver, "the former owner must reclaim the session with its one automatic takeover")

            let finalAttachCount = await backend.currentAttachCount()
            XCTAssertEqual(finalAttachCount, 1, "exactly one reattach, sent only after the restart wiped this client's attachment")
            let finalTakeoverCount = await backend.currentTakeoverCount()
            XCTAssertEqual(finalTakeoverCount, 1)
            let order = await backend.requestOrderSnapshot()
            let attachIndex = order.lastIndex(of: "attach")
            let takeoverIndex = order.lastIndex(of: "takeover")
            XCTAssertNotNil(attachIndex)
            XCTAssertNotNil(takeoverIndex)
            if let attachIndex, let takeoverIndex {
                XCTAssertLessThan(attachIndex, takeoverIndex, "the reattach must be sent before the takeover it hands back")
            }
        }

        /// Sibling of the reclaim test above, for the other half of the product contract (docs/spec.md
        /// line 313): a former owner reclaims only a session the bootstrap snapshot still shows as
        /// ownerless. When another pane (the Mac, here) took the session over while this client was
        /// disconnected, the returning owner comes back a mere viewer of that owner, exactly like a
        /// former viewer, and the ordinary Take Over affordance (`showsTakeOverAction`) is how the user
        /// gets it back from there — `attemptAutomaticTakeoverIfNeeded` itself carries no such guard, so
        /// this is what stops a returning owner from displacing a newer, legitimate one.
        ///
        /// The pre-existing "claim an ownerless session" mechanism can still fire its own takeover
        /// attempt on this same reconnect's bootstrap, ahead of the reattach (`start()` resets
        /// `hasAttemptedAutomaticTakeover`, and this client reads as not-owner the moment the bootstrap
        /// applies the Mac's snapshot, before this client has re-attached at all) — `RestartedDaemonBackend`
        /// rejects it, since this client is not yet attached, so it costs nothing beyond a
        /// `"takeover-rejected"` entry ahead of the reattach. The assertions below are scoped to what
        /// happened after the reattach, which is the only span the production gate under test controls.
        func testAFormerOwnerStaysAViewerWhenAnotherClientOwnsTheSessionAfterRestart() async throws {
            let backend = RestartedDaemonBackend(attachmentSnapshot: TerminalSessionAttachmentSnapshot())
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            let client = model.remoteClientForTesting
            let ownerAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: client.id, mode: .owner, attachedAt: "2026-06-04T14:23:30Z")
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot(clients: [client], attachments: [ownerAttachment]))

            model.start()
            _ = await backend.waitForSubscribeCount(1)
            await waitUntil("the bootstrap owner snapshot to apply", timeout: .seconds(5)) { model.isOwner }

            // The daemon restarts, and by the time this client reconnects another pane already took the
            // session over: the next bootstrap names a different client as owner, this client absent.
            let macClient = TerminalClient(
                id: "mac-pane", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:26:00Z")
            let macOwnerAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:26:00Z")
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwnerAttachment]))
            await backend.reportDisconnect(POSIXError(.ECONNRESET))

            let resubscribed = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(resubscribed, "a reset stream must reconnect")
            let reattached = await backend.waitForAttachCount(1, timeout: .seconds(5))
            XCTAssertTrue(reattached, "the former owner must still reattach as a viewer once its attachment is gone")

            // Nothing distinguishes "will never take over" from "hasn't taken over yet" here, so give the
            // model a beat past the reattach before asserting the negative.
            try? await Task.sleep(for: .milliseconds(300))

            let takeoverCountAfterRestart = await backend.currentTakeoverCount()
            XCTAssertEqual(takeoverCountAfterRestart, 0, "a former owner must not displace a newer, legitimate owner")
            let order = await backend.requestOrderSnapshot()
            guard let attachIndex = order.lastIndex(of: "attach") else {
                XCTFail("expected the reattach to have been recorded")
                return
            }
            let afterReattach = order[(attachIndex + 1)...]
            XCTAssertFalse(afterReattach.contains("takeover"), "no takeover must follow the reattach")
            XCTAssertFalse(afterReattach.contains("takeover-rejected"), "no takeover attempt at all must follow the reattach")

            XCTAssertFalse(model.isOwner, "a former owner must not read as owner when another client owns the session")
            XCTAssertTrue(model.showsTakeOverAction, "the locked state's Take Over affordance must be available")
        }

        /// A reattach that itself fails (a transient error on the attach request, not a real absence of
        /// the session) is handled exactly like a failed pre-subscribe attach: it throws out of `connect`
        /// into the outer `catch`, which retires the attempt (cancelling its stream) and lets
        /// `handleConnectError` schedule a redial, whose own pre-subscribe attach
        /// (`shouldAttachBeforeSubscribing`) is the retry. Nothing in this test reports a second
        /// disconnect; the redial is `connect`'s own doing, not something driven from outside it.
        ///
        /// Backgrounded throughout, for the same reason as the plain reattach test above: this is a
        /// viewer's recovery, not an owner's, so the pre-existing "claim an ownerless session" automatic
        /// takeover has no part to play here and is kept off entirely.
        func testAViewerWhoseReattachFailedRedialsAndAttachesBeforeSubscribing() async throws {
            let backend = RestartedDaemonBackend(attachmentSnapshot: TerminalSessionAttachmentSnapshot())
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.prepareForBackgrounding()

            let client = model.remoteClientForTesting
            let viewerAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:23:30Z")
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot(clients: [client], attachments: [viewerAttachment]))

            model.start()
            _ = await backend.waitForSubscribeCount(1)
            _ = await backend.waitForAttachCount(1)
            await waitUntil("the bootstrap attachment to land") {
                model.attachmentSnapshot.attachments.contains { $0.clientID == client.id && $0.detachedAt == nil }
            }

            // The daemon restarts: its next answer names nobody attached at all, and the reattach this
            // reconnect sends is made to fail once, the way a transient error on that one request would.
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot())
            await backend.setFailNextAttach()
            await backend.reportDisconnect(POSIXError(.ECONNRESET))

            let resubscribed = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(resubscribed, "a reset stream must reconnect even though the reattach it triggers will fail")
            let failedReattach = await backend.waitForAttachCount(2, timeout: .seconds(5))
            XCTAssertTrue(failedReattach, "the reconnect's empty bootstrap snapshot must still trigger a reattach attempt")

            let snapshotAfterFailure = await backend.currentAttachmentSnapshot()
            XCTAssertFalse(
                snapshotAfterFailure.attachments.contains { $0.clientID == client.id && $0.detachedAt == nil },
                "a failed attach must not register the client, the same as a real daemon that rejected it")

            // No second disconnect is reported here: the failed reattach throws into `connect`'s own
            // outer `catch`, which retires this attempt and schedules a redial through
            // `handleConnectError` on its own, without anything external driving it. Reaching a third
            // subscribe with nothing but that scheduled redial to cause it is what proves the redial
            // happened; the fixed one-second cadence for a non-transient daemon refusal, plus the 5 s
            // budget below, leaves ample room for it to land.
            let resubscribedAgain = await backend.waitForSubscribeCount(3, timeout: .seconds(5))
            XCTAssertTrue(resubscribedAgain, "the failed reattach must schedule its own redial, opening a third stream")
            let reattachedAgain = await backend.waitForAttachCount(3, timeout: .seconds(5))
            XCTAssertTrue(reattachedAgain, "the redial must attach again, recovering from the earlier failure")

            // This third attach must be the redial's pre-subscribe path (`shouldAttachBeforeSubscribing`),
            // not the reattach block the second connect already failed out of: it must be recorded before
            // the third subscribe, not after it.
            let order = await backend.requestOrderSnapshot()
            let thirdAttachIndex = order.lastIndex(of: "attach")
            let thirdSubscribeIndex = order.lastIndex(of: "subscribe")
            XCTAssertNotNil(thirdAttachIndex)
            XCTAssertNotNil(thirdSubscribeIndex)
            if let thirdAttachIndex, let thirdSubscribeIndex {
                XCTAssertLessThan(
                    thirdAttachIndex, thirdSubscribeIndex,
                    "the recovering attach must be sent before its reconnect subscribes, proving it took the pre-subscribe path")
            }

            let finalSnapshot = await backend.currentAttachmentSnapshot()
            XCTAssertTrue(
                finalSnapshot.attachments.contains { $0.clientID == client.id && $0.detachedAt == nil },
                "the recovering attach must register the client")
            let takeoverCount = await backend.currentTakeoverCount()
            XCTAssertEqual(takeoverCount, 0, "a former viewer recovering this way must not take over")
            let mode = await backend.lastAttachedMode()
            XCTAssertEqual(mode, .viewer, "the recovering attach must stay a viewer attach")
        }

        /// The P1 this exercises: `connect()`'s bootstrap read is only one of the two sources a
        /// reconnect's armed reattach check can settle from. When the bootstrap read answers nothing (a
        /// request failure, or its own fixed timeout) before the subscription's stream has delivered
        /// anything, deciding the check right there and then would skip it forever: `hasAttachedToSession`
        /// is still whatever it was before this connect (`true`, since this client held an attachment
        /// going into it), so a decision made at that moment reads as "still attached" and reattaches
        /// nothing. The stream's own payload, arriving after, is what finally sets `hasAttachedToSession`
        /// false and must still be able to trigger the reattach then, which is exactly what
        /// `applyReducedState`'s consume site (armed by `connect()`, not fixed to its bootstrap call)
        /// covers: whichever source produces the first snapshot naming this client gone is the one that
        /// settles the check.
        ///
        /// Backgrounded throughout, for the same reason as the plain reattach test above: this is a
        /// viewer's recovery, not an owner's, so the pre-existing "claim an ownerless session" automatic
        /// takeover has no part to play here and is kept off entirely.
        func testAViewerReattachesFromTheStreamPayloadWhenTheBootstrapReadIsUnavailable() async throws {
            let backend = RestartedDaemonBackend(attachmentSnapshot: TerminalSessionAttachmentSnapshot())
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.prepareForBackgrounding()

            let client = model.remoteClientForTesting
            let viewerAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:23:30Z")
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot(clients: [client], attachments: [viewerAttachment]))

            model.start()
            _ = await backend.waitForSubscribeCount(1)
            _ = await backend.waitForAttachCount(1)
            await waitUntil("the bootstrap attachment to land") {
                model.attachmentSnapshot.attachments.contains { $0.clientID == client.id && $0.detachedAt == nil }
            }

            // The daemon restarts: its next answer would name nobody attached at all, except this
            // reconnect's bootstrap read is made to fail outright, so it never gets to answer anything.
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot())
            await backend.setFailNextStateRead()
            await backend.reportDisconnect(POSIXError(.ECONNRESET))

            let resubscribed = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(resubscribed, "a reset stream must reconnect even though its bootstrap read will fail")
            let bootstrapFailed = await backend.waitForStateReadCount(2, timeout: .seconds(5))
            XCTAssertTrue(bootstrapFailed, "the reconnect's own bootstrap read must have been attempted (and failed) by now")

            // The subscription this reconnect opens delivers the daemon's initial export, which carries the
            // empty snapshot the bootstrap read never got to answer with: the reconnect's other, equally
            // authoritative source for the same fact.
            let reattached = await backend.waitForAttachCount(2, timeout: .seconds(5))
            XCTAssertTrue(reattached, "the stream's own payload must trigger the reattach the failed bootstrap read could not")

            let order = await backend.requestOrderSnapshot()
            XCTAssertEqual(order.filter { $0 == "attach" }.count, 2, "exactly the first connect's attach and this recovering one")
            // What proves the read did not trigger it: the recovering attach is sent after this reconnect's
            // own subscribe, so the payload it reacted to came off the stream. A reattach driven by the
            // bootstrap read would have been sent before the subscribe, the way the first connect's
            // pre-subscribe attach is.
            XCTAssertGreaterThan(
                order.lastIndex(of: "attach") ?? -1, order.lastIndex(of: "subscribe") ?? -1,
                "a failed bootstrap read must not be what triggered the reattach")
            let finalSnapshot = await backend.currentAttachmentSnapshot()
            XCTAssertTrue(
                finalSnapshot.attachments.contains { $0.clientID == client.id && $0.detachedAt == nil },
                "the recovering attach must register the client")
            let takeoverCount = await backend.currentTakeoverCount()
            XCTAssertEqual(takeoverCount, 0, "a former viewer recovering this way must not take over")
            let mode = await backend.lastAttachedMode()
            XCTAssertEqual(mode, .viewer, "the recovering attach must stay a viewer attach")
        }

        /// The bootstrap read answers for the reconnect on its own, without waiting on the stream. A quiet
        /// session's subscription can be up for a long time before it exports anything, and a client with
        /// no attachment has every input and takeover it sends refused for as long as that takes, so the
        /// read this connect already makes is what has to settle it. A daemon restart is the shape that
        /// takes: its start clears every client and attachment row, so the snapshot the read answers with
        /// names nobody at all, this client included, and no owner either.
        func testAReconnectReattachesFromItsBootstrapReadWhenTheStreamExportsNothing() async throws {
            let backend = RestartedDaemonBackend(attachmentSnapshot: TerminalSessionAttachmentSnapshot())
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.prepareForBackgrounding()

            let client = model.remoteClientForTesting
            let viewerAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:23:30Z")
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot(clients: [client], attachments: [viewerAttachment]))

            model.start()
            _ = await backend.waitForSubscribeCount(1)
            _ = await backend.waitForAttachCount(1)
            await waitUntil("the first connect's attachment to be confirmed on the stream") {
                model.attachmentSnapshot.attachments.contains { $0.clientID == client.id && $0.detachedAt == nil }
            }

            // The daemon restarts: every row is gone, so its next answer names nobody attached and no
            // owner. The subscription this reconnect opens stays silent, leaving the bootstrap read as the
            // only thing that can report it.
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot())
            await backend.setSuppressNextInitialExport()
            await backend.reportDisconnect(POSIXError(.ECONNRESET))

            let resubscribed = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertTrue(resubscribed, "a reset stream must reconnect")
            let reattached = await backend.waitForAttachCount(2, timeout: .seconds(5))
            XCTAssertTrue(reattached, "the bootstrap read's empty, ownerless snapshot must re-attach this client on its own")

            let order = await backend.requestOrderSnapshot()
            XCTAssertEqual(order.filter { $0 == "attach" }.count, 2, "exactly the first connect's attach and this recovering one")
            let mode = await backend.lastAttachedMode()
            XCTAssertEqual(mode, .viewer, "the recovering attach must stay a viewer attach")
            let finalSnapshot = await backend.currentAttachmentSnapshot()
            XCTAssertTrue(
                finalSnapshot.attachments.contains { $0.clientID == client.id && $0.detachedAt == nil },
                "the recovering attach must register the client")
            let takeoverCount = await backend.currentTakeoverCount()
            XCTAssertEqual(takeoverCount, 0, "a former viewer recovering this way must not take over")
        }

        /// codex P1 (round 6): `lifecycle` and `clientID` alone do not tell a reconnect's own settling
        /// snapshot apart from a snapshot the connection it replaces submitted just before disconnecting
        /// -- a reconnect keeps both unchanged from the connection it replaces, so a stale submission that
        /// still names this client attached can pass `isCurrentStateRefresh` and clear the check without
        /// ever reattaching, if its reduction happens to land after `connect()` has already armed the
        /// check. `TerminalReattachCheckAfterReconnect.submissionBoundary` is what tells them apart: only
        /// a snapshot *submitted* after the boundary was produced by this reconnect.
        ///
        /// Reproducing the "after" half deterministically (not racing a sleep) needs two pieces:
        ///   - The stale payload's own *submission* is what must predate the boundary, and that part is
        ///     free: `submitLatestState` bumps `submittedStateCount` synchronously on the call that makes
        ///     it, so submitting before `reportDisconnect` below guarantees the boundary `connect()` reads
        ///     off it afterwards already covers it.
        ///   - Its *application* has to land after the boundary was read, which is not free: reduction
        ///     runs off the main actor, and a single payload reduces fast enough to almost always finish
        ///     well inside the ~150ms silent-redial delay, landing before the check even exists. A large,
        ///     ordinary burst of `paddingCount` unrelated payloads submitted immediately ahead of the
        ///     stale one exploits the pipeline's own strict FIFO reduction (`TerminalRemoteStateReductionPipeline`'s
        ///     single consumer loop) to push its reduction out past that delay: the stale payload cannot
        ///     even begin reducing until every padding payload ahead of it already has, which reliably
        ///     outlasts the redial on any machine this suite runs on. This can only make the test
        ///     conservative, never flaky: if the burst ever fails to outlast the delay, the stale payload
        ///     resolves before the check exists, both fixed and unfixed code behave identically (a
        ///     no-op), and the assertions below still pass because the real settling snapshot fired
        ///     afterwards settles the check on its own -- the test would just fail to have exercised the
        ///     bug that round, never fail on correct code. Each padding frame carries its own, strictly
        ///     increasing revision (a repeated one would have the reducer judge every frame after the
        ///     first no newer than what it already retained, dropping it and arming an unrelated
        ///     render-update resync fetch that races this test's own single-shot bootstrap-read failure
        ///     below for which `.state` call actually fails), and `renderUpdateResyncIntervalForTesting`
        ///     is pinned far out of reach so the burst's own duration cannot arm that resync on a timer
        ///     either.
        ///
        /// The bootstrap read is made to fail (as in the stream-payload test above), so the *only* two
        /// candidates left to settle the check are the stale payload and this test's own later `fireFrame`
        /// -- isolating whether the boundary, not `lifecycle`/`clientID` alone, is what keeps the former
        /// from being mistaken for the latter. Awaiting a sentinel payload submitted after the stale one
        /// (`applyLatestState`) is what proves the stale payload has actually finished applying, by the
        /// same strict-ordering guarantee `testAnAwaitedApplyLandsAfterEverythingSubmittedBeforeIt`
        /// documents, before this test moves on to fire the real settling snapshot.
        func testAStalePayloadFromTheConnectionAReconnectReplacesDoesNotConsumeItsReattachCheck() async throws {
            let backend = RestartedDaemonBackend(attachmentSnapshot: TerminalSessionAttachmentSnapshot())
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            // The padding burst below takes well over the default 1-second trailing render-update-resync
            // interval to drain, which would otherwise arm an unrelated out-of-band `.state` refresh
            // (`reason: "render_update_resync"`) that races this test's own single-shot `setFailNextStateRead`
            // for which `.state` call actually fails -- letting a resync consume it instead of the
            // reconnect's own bootstrap read, and leaving that bootstrap read to succeed and settle the
            // check on its own before this test's checkpoint. Pinning the interval far out of reach removes
            // that confound: the only `.state` call in play is the reconnect's own bootstrap read.
            model.renderUpdateResyncIntervalForTesting = 1_000_000
            model.prepareForBackgrounding()

            let client = model.remoteClientForTesting
            let viewerAttachment = TerminalAttachment(
                sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:23:30Z")
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot(clients: [client], attachments: [viewerAttachment]))

            model.start()
            _ = await backend.waitForSubscribeCount(1)
            _ = await backend.waitForAttachCount(1)
            await waitUntil("the bootstrap attachment to land") {
                model.attachmentSnapshot.attachments.contains { $0.clientID == client.id && $0.detachedAt == nil }
            }

            // The connection about to be replaced submits one more payload that still names this client
            // attached -- exactly what a real stream frame racing its own disconnect looks like -- behind
            // a large burst of unrelated padding that exists only to keep the reduce queue busy past the
            // reconnect's arm (see the doc comment above). Both go out before `reportDisconnect`, so both
            // predate whatever boundary the reconnect arms with.
            // Each padding frame carries its own, strictly increasing revision: a repeated revision would
            // have the reducer judge every frame after the first no newer than what it already retained,
            // dropping it and requesting a render-update resync (`shouldUseFrame`) -- an unrelated
            // out-of-band `.state` fetch this test does not want competing with its own bootstrap-read
            // failure injection below.
            let paddingCount = 3_000
            let paddingFrames = try (0..<paddingCount).map { index in
                try TerminalViewerModelTests.framedState(
                    text: String(repeating: "x", count: 2_000), sessionRevision: UInt64(index + 1), ownerEpoch: 1, emittedAt: "2026-06-04T14:23:31Z")
            }
            for paddingFrame in paddingFrames { model.submitLatestState(paddingFrame, isOutOfBand: false) }
            let staleStillAttachedPayload = TerminalViewerModelTests.runningTerminalState(
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [viewerAttachment]),
                emittedAt: "2026-06-04T14:23:32Z")
            model.submitLatestState(staleStillAttachedPayload, isOutOfBand: false)

            // The daemon restarts: its next answer would name nobody attached at all, except this
            // reconnect's bootstrap read is made to fail outright (as in the stream-payload test above),
            // so the stale payload above and this test's own later `fireFrame` are the only two snapshots
            // left that could possibly settle the check.
            await backend.setAttachmentSnapshot(TerminalSessionAttachmentSnapshot())
            await backend.setFailNextStateRead()
            await backend.reportDisconnect(POSIXError(.ECONNRESET))

            // Both of these can only be true once `connect()` has already run past its arm, which is the
            // very first thing it does: confirms the boundary the reconnect armed with already covers the
            // padding burst and the stale payload above.
            let resubscribed = await backend.waitForSubscribeCount(2, timeout: .seconds(30))
            XCTAssertTrue(resubscribed, "a reset stream must reconnect even though its bootstrap read will fail")
            let bootstrapFailed = await backend.waitForStateReadCount(2, timeout: .seconds(30))
            XCTAssertTrue(bootstrapFailed, "the reconnect's own bootstrap read must have been attempted (and failed) by now")

            // Drains the burst and the stale payload behind it: this resolves only once both have been
            // fully accounted for, by the same strict-ordering guarantee
            // `testAnAwaitedApplyLandsAfterEverythingSubmittedBeforeIt` documents.
            await model.applyLatestState(Self.outputState(title: "sentinel", emittedAt: "2026-06-04T14:23:33Z"), isOutOfBand: false)

            // Nothing has reattached: the fixed code must have left the stale payload's attempt to settle
            // the check unconsumed rather than clearing it, since a submission at or below the boundary
            // never triggers the block that starts a reattach.
            let attachCountAfterStalePayload = await backend.currentAttachCount()
            XCTAssertEqual(
                attachCountAfterStalePayload, 1,
                "a stale payload from the connection this reconnect replaced must not have triggered anything, correct or otherwise")

            // The subscription's own stream now delivers the empty-snapshot payload the bootstrap read
            // never got to answer with -- the reconnect's genuine settling snapshot, submitted (and so
            // indexed) after the boundary.
            let emptySnapshotFrame = TerminalViewerModelTests.runningTerminalState(
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:24:00Z")
            await backend.fireFrame(emptySnapshotFrame)

            let reattached = await backend.waitForAttachCount(2, timeout: .seconds(10))
            XCTAssertTrue(
                reattached,
                "the check must still be armed for the reconnect's own settling snapshot: a stale payload the connection being replaced "
                    + "submitted before disconnecting must not have consumed it")

            let takeoverCount = await backend.currentTakeoverCount()
            XCTAssertEqual(takeoverCount, 0, "a former viewer recovering this way must not take over")
            let mode = await backend.lastAttachedMode()
            XCTAssertEqual(mode, .viewer, "the recovering attach must stay a viewer attach")
        }

        /// K2 regression: a keystroke queued behind a conclusively failing send must not go out once a
        /// new stream is up. Mirrors Mac's `RemoteGhosttySessionHost.reportInputFailure`, which calls
        /// `inputQueue.cancelAll()` exactly when `reportFailedInputSend` returns `true` (a teardown), so
        /// a backlog addressed to a link that failure just proved is gone never gets a second life on the
        /// replacement stream. Before the fix, `handleInputSendError` tore the stream down but left
        /// `inputSendQueue` draining, so "b" queued right behind the failing "a" would still reach the
        /// transport. "a" fails on the transport's first `.key` send; "b" is enqueued immediately after,
        /// while "a" is still being handled, so it sits behind "a" in the serial queue and never starts
        /// until `cancelQueuedInputSends()` has already cancelled it.
        func testInputSendFailingWithAConnectionResetDropsQueuedSendsBehindIt() async throws {
            let transport = InputConnectionResetForSpecificKeyRequestTransport()
            let backend = StageTrackerTestBackend(transportFactory: { transport })
            let bridgeClient = SpacesDeviceAPIClient(settings: settings(), backend: backend)
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }
            model.connectionBannerGraceSecondsForTesting = 30
            model.start()
            await backend.waitForSubscribeCount(1)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)

            await model.sendKey("a")
            await model.sendKey("b")

            await waitUntil("the stage to reach reconnecting", timeout: .seconds(5)) { model.connectionStage == .reconnecting }
            // Give any wrongly-undropped "b" send a chance to reach the transport before asserting its
            // absence; the redial below is proof the model finished reacting to "a"'s failure.
            _ = await backend.waitForSubscribeCount(2, timeout: .seconds(5))
            XCTAssertEqual(transport.sentKeysSoFar(), [], "a keystroke queued behind a conclusively failing send must be dropped, not delivered")
        }

        /// Hands out stream handles and keeps the last stream's `onDisconnect`, so a test can make the
        /// stream end exactly the way the liveness watch ends it. Every request is answered `ok`, so the
        /// reconnect the disconnect triggers gets as far as subscribing again.
        private actor StalledStreamBackend: SpacesDeviceAPIBackend {
            private var subscribeCount = 0
            private var onDisconnect: (@MainActor (SpacesDeviceAPIStreamDisconnect) -> Void)?

            nonisolated func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport { StalledStreamRequestTransport() }

            nonisolated func openSessionStream(
                request: SpacesDeviceAPIRequest, initialEventTimeout: Duration,
                onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
                onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
            ) async throws -> SpacesDeviceAPIStreamHandle {
                await recordSubscribe(onDisconnect: onDisconnect)
                return SpacesDeviceAPIStreamHandle {}
            }

            /// Polls rather than parking a continuation, so a subscribe that never happens fails the
            /// assertion in the test instead of hanging the run.
            @discardableResult func waitForSubscribeCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
                let deadline = ContinuousClock().now + timeout
                while ContinuousClock().now < deadline {
                    if subscribeCount >= count { return true }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return subscribeCount >= count
            }

            func reportDisconnect(_ error: any Error) async {
                let handler = onDisconnect
                await MainActor.run { handler?(SpacesDeviceAPIStreamDisconnect(error: error)) }
            }

            private func recordSubscribe(onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void) {
                subscribeCount += 1
                self.onDisconnect = onDisconnect
            }
        }

        private struct StalledStreamRequestTransport: SpacesDeviceAPIRequestTransport {
            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if let acknowledgement = TerminalViewerModelTests.attachAcknowledgement(for: request) { return acknowledgement }
                // The reconnect reads state before it resubscribes, and a read that answers `ok` without
                // terminal state is itself an error the viewer reports — so answer it the way the daemon
                // would, leaving the stall as the only thing under test.
                if case .state = request.command {
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Reproduces a daemon that wipes its `terminal_clients`/`terminal_attachments` tables on every
        /// start: `.state` reads answer with whatever attachment snapshot the test currently holds
        /// (settable mid-run via `setAttachmentSnapshot`, so a test can simulate the daemon losing this
        /// client's row between two reads).
        ///
        /// `.attach` registers the requesting client into `attachmentSnapshot` (mirroring what a real
        /// attach does to the daemon's row) and `.takeover` requires the requesting client to currently
        /// hold a live attachment there, rejecting (`ok: false`) a takeover from a client the snapshot
        /// does not name — exactly what a real daemon can do, since a restart's wipe leaves it with no
        /// record of a client that has not yet re-attached. This is not incidental realism: the
        /// pre-existing "claim an ownerless running session" automatic takeover
        /// (`TerminalViewerModel.attemptAutomaticTakeoverIfNeeded`) fires on every applied state,
        /// including the reconnect's own bootstrap, and would otherwise race the reattach this backend is
        /// built to exercise — modeling the daemon's real gate is what makes the accepted takeover
        /// provably wait on the reattach that makes it legitimate, rather than depending on which of two
        /// in-memory async calls happens to reach the mock first.
        ///
        /// Requests are counted by kind and recorded in the order they were processed (this actor
        /// serializes them), so a test can check ordering (a reattach must precede the takeover it hands
        /// back) as well as totals. `takeoverCount`/`waitForTakeoverCount` count only *accepted*
        /// takeovers: a takeover a real daemon would reject changes nothing a test needs to see.
        private actor RestartedDaemonBackend: SpacesDeviceAPIBackend {
            private var attachmentSnapshot: TerminalSessionAttachmentSnapshot
            private var subscribeCount = 0
            private var onDisconnect: (@MainActor (SpacesDeviceAPIStreamDisconnect) -> Void)?
            /// Every stream this backend has opened, in subscribe order, so `fireFrame` can deliver a
            /// payload through the most recent one's `onEvent`, exactly as a real stream frame would.
            private var openedStreamEventHandlers: [@MainActor (GhosttyRemoteSessionStatePayload) -> Void] = []
            private var stateReadCount = 0
            private var attachCount = 0
            private var takeoverCount = 0
            private var lastAttachedModeValue: TerminalAttachmentMode?
            private var requestOrder: [String] = []
            private var sequence = 0
            /// One-shot switch: when set, the next `.attach` is answered `ok: false` and, unlike a
            /// succeeding attach, does not register the requesting client into `attachmentSnapshot` (a
            /// real daemon that failed the attach wrote no row for it either). Clears itself the moment it
            /// is consumed, so only that one attach fails.
            private var failNextAttach = false
            /// One-shot switch: when set, the next `.state` read throws instead of answering, the way a
            /// request failure looks from `connect()`'s bootstrap read. `ETIMEDOUT` is transient
            /// (`TerminalViewerModel.isTransientReconnectError`), so `readStateForConnectBootstrap`
            /// (`ignoreTransientTimeout: true`) settles it as "answered nothing" with no error banner,
            /// exactly like the read's own fixed timeout expiring for real — reproducing that outcome
            /// without a test actually waiting one out.
            private var failNextStateRead = false
            /// One-shot switch: when set, the next subscription opens without delivering the daemon's
            /// initial export, the way a stream that is up but has not exported yet looks from the client.
            /// Clears itself the moment it is consumed, so only that one subscription stays silent.
            private var suppressNextInitialExport = false

            init(attachmentSnapshot: TerminalSessionAttachmentSnapshot) { self.attachmentSnapshot = attachmentSnapshot }

            nonisolated func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport { RestartedDaemonRequestTransport(backend: self) }

            nonisolated func openSessionStream(
                request: SpacesDeviceAPIRequest, initialEventTimeout: Duration,
                onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
                onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
            ) async throws -> SpacesDeviceAPIStreamHandle {
                await recordSubscribe(onEvent: onEvent, onDisconnect: onDisconnect)
                return SpacesDeviceAPIStreamHandle {}
            }

            private func recordSubscribe(
                onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
                onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
            ) async {
                subscribeCount += 1
                requestOrder.append("subscribe")
                openedStreamEventHandlers.append(onEvent)
                self.onDisconnect = onDisconnect
                // Every real subscription opens with the daemon's initial export of the session, and that
                // payload is the only thing that can confirm this client's attachment: a `.state` read
                // reports a loss but never confirms one. Without it the model treats the attachment as one
                // no stream ever confirmed and gives it up on the next redial.
                guard !suppressNextInitialExport else {
                    suppressNextInitialExport = false
                    return
                }
                await deliverCurrentState(to: onEvent)
            }

            /// Publishes the session as it stands on the live stream, which is what a real daemon does after
            /// every attachment change and before it answers the control request that made it.
            private func broadcastCurrentState() async {
                guard let handler = openedStreamEventHandlers.last else { return }
                await deliverCurrentState(to: handler)
            }

            private func deliverCurrentState(to handler: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void) async {
                sequence += 1
                let payload = TerminalViewerModelTests.runningTerminalState(
                    attachmentSnapshot: attachmentSnapshot, emittedAt: Self.emittedAt(sequence))
                await MainActor.run { handler(payload) }
            }

            func setAttachmentSnapshot(_ snapshot: TerminalSessionAttachmentSnapshot) { attachmentSnapshot = snapshot }

            func setFailNextAttach(_ value: Bool = true) { failNextAttach = value }
            func setFailNextStateRead(_ value: Bool = true) { failNextStateRead = value }
            func setSuppressNextInitialExport(_ value: Bool = true) { suppressNextInitialExport = value }

            func reportDisconnect(_ error: any Error) async {
                let handler = onDisconnect
                await MainActor.run { handler?(SpacesDeviceAPIStreamDisconnect(error: error)) }
            }

            /// Delivers `payload` on the most recently opened stream's `onEvent`, exactly as a real stream
            /// frame would: the other, equally authoritative source `applyReducedState` can settle a
            /// reconnect's armed reattach check from, alongside the bootstrap read.
            func fireFrame(_ payload: GhosttyRemoteSessionStatePayload) async {
                guard let handler = openedStreamEventHandlers.last else { return }
                await MainActor.run { handler(payload) }
            }

            func send(_ request: SpacesDeviceAPIRequest) async throws -> SpacesDeviceAPIResponse {
                sequence += 1
                switch request.command {
                case .state:
                    stateReadCount += 1
                    if failNextStateRead {
                        failNextStateRead = false
                        throw POSIXError(.ETIMEDOUT)
                    }
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(attachmentSnapshot: attachmentSnapshot, emittedAt: Self.emittedAt(sequence)))
                case .terminalControl(let payload) where payload.action == .attach:
                    attachCount += 1
                    lastAttachedModeValue = payload.attachmentMode
                    requestOrder.append("attach")
                    if failNextAttach {
                        failNextAttach = false
                        return SpacesDeviceAPIResponse(ok: false, message: "RestartedDaemonBackend: attach failed")
                    }
                    // Registers the attaching client into the live snapshot, the way a real attach
                    // registers a row with the daemon: this is what a later takeover checks.
                    if let attachingClient = payload.client {
                        let attachment = TerminalAttachment(
                            sessionID: "terminal-session", clientID: attachingClient.id, mode: payload.attachmentMode ?? .viewer,
                            attachedAt: Self.emittedAt(sequence))
                        var clients = attachmentSnapshot.clients.filter { $0.id != attachingClient.id }
                        clients.append(attachingClient)
                        var attachments = attachmentSnapshot.attachments.filter { $0.clientID != attachingClient.id }
                        attachments.append(attachment)
                        attachmentSnapshot = TerminalSessionAttachmentSnapshot(clients: clients, attachments: attachments)
                    }
                    // The daemon broadcasts the new attachment to its subscribers before it loads the state
                    // it answers the attach with, and answers with that state rather than a bare `ok`.
                    await broadcastCurrentState()
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(attachmentSnapshot: attachmentSnapshot, emittedAt: Self.emittedAt(sequence)))
                case .terminalControl(let payload) where payload.action == .takeover:
                    // A real daemon has no row for a client that has never attached (or whose row a
                    // restart wiped), so it cannot promote one to owner. Rejecting here is what makes the
                    // pre-existing "claim an ownerless running session" automatic takeover harmless when
                    // it races ahead of a reattach still in flight, instead of letting it reach ownership
                    // through a client this backend has no record of.
                    guard let requestingClientID = payload.clientID,
                        attachmentSnapshot.attachments.contains(where: { $0.clientID == requestingClientID && $0.detachedAt == nil }),
                        let owningClient = attachmentSnapshot.clients.first(where: { $0.id == requestingClientID })
                    else {
                        requestOrder.append("takeover-rejected")
                        return SpacesDeviceAPIResponse(ok: false, message: "RestartedDaemonBackend: client not attached")
                    }
                    takeoverCount += 1
                    requestOrder.append("takeover")
                    let ownerAttachment = TerminalAttachment(
                        sessionID: "terminal-session", clientID: owningClient.id, mode: .owner, attachedAt: Self.emittedAt(sequence))
                    let ownerSnapshot = TerminalSessionAttachmentSnapshot(clients: [owningClient], attachments: [ownerAttachment])
                    attachmentSnapshot = ownerSnapshot
                    await broadcastCurrentState()
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(attachmentSnapshot: ownerSnapshot, emittedAt: Self.emittedAt(sequence)))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }

            @discardableResult func waitForSubscribeCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
                let deadline = ContinuousClock().now + timeout
                while ContinuousClock().now < deadline {
                    if subscribeCount >= count { return true }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return subscribeCount >= count
            }

            @discardableResult func waitForAttachCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
                let deadline = ContinuousClock().now + timeout
                while ContinuousClock().now < deadline {
                    if attachCount >= count { return true }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return attachCount >= count
            }

            @discardableResult func waitForTakeoverCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
                let deadline = ContinuousClock().now + timeout
                while ContinuousClock().now < deadline {
                    if takeoverCount >= count { return true }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return takeoverCount >= count
            }

            @discardableResult func waitForStateReadCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
                let deadline = ContinuousClock().now + timeout
                while ContinuousClock().now < deadline {
                    if stateReadCount >= count { return true }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return stateReadCount >= count
            }

            func currentAttachCount() -> Int { attachCount }
            func currentTakeoverCount() -> Int { takeoverCount }
            func lastAttachedMode() -> TerminalAttachmentMode? { lastAttachedModeValue }
            func requestOrderSnapshot() -> [String] { requestOrder }
            func currentAttachmentSnapshot() -> TerminalSessionAttachmentSnapshot { attachmentSnapshot }

            /// A strictly increasing timestamp per answered request, so the reducer (which orders
            /// out-of-band payloads by `emittedAt`) never refuses one of this backend's own state reads
            /// or takeover acknowledgments as stale against a previous one.
            private nonisolated static func emittedAt(_ sequence: Int) -> String {
                let base = ISO8601DateFormatter().date(from: "2026-06-04T14:23:30Z")!
                return ISO8601DateFormatter().string(from: base.addingTimeInterval(Double(sequence)))
            }
        }

        private struct RestartedDaemonRequestTransport: SpacesDeviceAPIRequestTransport {
            let backend: RestartedDaemonBackend

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse { try await backend.send(request) }

            func close() async {}
        }

        /// Serves the automatic-reattach path with no real network: the first attach parks until the test
        /// releases it and then fails the way a command-channel connection failure does, every later
        /// request answers the way the daemon would, and every subscription is a handle that delivers
        /// nothing. That leaves the redial a failed reattach hands recovery to as the only thing moving,
        /// countable as one subscribe and one further attach.
        private actor LostAttachmentRedialBackend: SpacesDeviceAPIBackend {
            private let requestTransport = LostAttachmentRedialTransport()
            private var subscribes = 0

            nonisolated func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport { requestTransport }

            nonisolated func openSessionStream(
                request: SpacesDeviceAPIRequest, initialEventTimeout: Duration,
                onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
                onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
            ) async throws -> SpacesDeviceAPIStreamHandle {
                await recordSubscribe()
                return SpacesDeviceAPIStreamHandle {}
            }

            nonisolated func attachModes() -> [TerminalAttachmentMode?] { requestTransport.attachModes() }
            nonisolated func releaseHeldAttach() { requestTransport.releaseHeldAttach() }
            func subscribeCount() -> Int { subscribes }

            /// Polls rather than parking a continuation, so an attach that never happens fails the
            /// assertion in the test instead of hanging the run.
            func waitForAttachCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
                let deadline = ContinuousClock().now + timeout
                while ContinuousClock().now < deadline {
                    if requestTransport.attachModes().count >= count { return true }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return requestTransport.attachModes().count >= count
            }

            func waitForSubscribeCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
                let deadline = ContinuousClock().now + timeout
                while ContinuousClock().now < deadline {
                    if subscribes >= count { return true }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return subscribes >= count
            }

            private func recordSubscribe() { subscribes += 1 }
        }

        /// Holds the reclaim's takeover inside the request handler until the test releases it, so a payload
        /// can be delivered while that takeover is genuinely in flight rather than raced against it.
        private actor ReclaimTakeoverGate {
            private var didStart = false
            private var isReleased = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func markStarted() {
                didStart = true
                let waiters = startWaiters
                startWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }

            func waitForStart() async {
                guard !didStart else { return }
                await withCheckedContinuation { continuation in startWaiters.append(continuation) }
            }

            func waitForRelease() async {
                guard !isReleased else { return }
                await withCheckedContinuation { continuation in releaseWaiters.append(continuation) }
            }

            func release() {
                isReleased = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }

        /// The daemon a lease-expired owner recovers against: another client owns the session throughout,
        /// and every heartbeat is answered as a live lease, which is what the recovery's own attach makes
        /// true (and stays true when that attach's answer is lost rather than its request). Shared across
        /// the transports the model's channels build, since the counts are one run's.
        private final class ExpiredOwnerRecoveryTracker: @unchecked Sendable {
            static let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:25:00Z")
            static let macOwnedSnapshot = TerminalSessionAttachmentSnapshot(
                clients: [macClient],
                attachments: [
                    TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:25:00Z")
                ])

            private let lock = NSLock()
            private let failsFirstAttach: Bool
            private var attaches = 0
            private var takeovers = 0
            private var heartbeats = 0
            private var attachedClient: TerminalClient?

            init(failsFirstAttach: Bool) { self.failsFirstAttach = failsFirstAttach }

            /// Records the attach and answers whether this one is the failure the test asked for.
            func recordAttach(_ client: TerminalClient) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                attaches += 1
                attachedClient = client
                return failsFirstAttach && attaches == 1
            }

            func recordTakeover() {
                lock.lock()
                takeovers += 1
                lock.unlock()
            }

            func recordHeartbeat() {
                lock.lock()
                heartbeats += 1
                lock.unlock()
            }

            func attachCount() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return attaches
            }

            func takeoverCount() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return takeovers
            }

            func heartbeatCount() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return heartbeats
            }

            func state(emittedAt: String) -> GhosttyRemoteSessionStatePayload {
                lock.lock()
                let client = attachedClient
                lock.unlock()
                let macOwner = TerminalAttachment(
                    sessionID: "terminal-session", clientID: Self.macClient.id, mode: .owner, attachedAt: "2026-06-04T14:25:00Z")
                guard let client else {
                    return TerminalViewerModelTests.runningTerminalState(
                        attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [Self.macClient], attachments: [macOwner]),
                        emittedAt: emittedAt)
                }
                let viewer = TerminalAttachment(sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:26:30Z")
                return TerminalViewerModelTests.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [Self.macClient, client], attachments: [macOwner, viewer]),
                    emittedAt: emittedAt)
            }
        }

        /// Serves one `ExpiredOwnerRecoveryTracker` over the model's own command channels, so the recovery's
        /// attach and the resume's heartbeat queue against each other exactly as they do in production.
        private struct ExpiredOwnerRecoveryTransport: SpacesDeviceAPIRequestTransport {
            let tracker: ExpiredOwnerRecoveryTracker
            /// Answers every heartbeat the way the daemon answers one from a client whose lease it expired.
            var expiresLease = false

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .terminalControl(let payload) = request.command {
                    switch payload.action {
                    case .attach:
                        guard let client = payload.client else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                        if tracker.recordAttach(client) {
                            // The daemon applied the attach and the connection dropped before its answer
                            // came back, which is why the heartbeat behind it still renews a live lease.
                            throw SpacesPinnedTLSConnectionError.connectionClosed
                        }
                        return TerminalViewerModelTests.terminalStateResponse(tracker.state(emittedAt: "2026-06-04T14:26:30Z"))
                    case .heartbeat:
                        tracker.recordHeartbeat()
                        if expiresLease { return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound) }
                        return TerminalViewerModelTests.terminalStateResponse(tracker.state(emittedAt: "2026-06-04T14:26:35Z"))
                    case .takeover:
                        tracker.recordTakeover()
                        return TerminalViewerModelTests.terminalStateResponse(tracker.state(emittedAt: "2026-06-04T14:26:40Z"))
                    default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                    }
                }
                if case .state = request.command {
                    return TerminalViewerModelTests.terminalStateResponse(tracker.state(emittedAt: "2026-06-04T14:26:36Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Records the client record each attach carried, so a test can publish the broadcast the daemon
        /// would publish for that attachment. A lock rather than an actor because `waitUntil` polls a
        /// synchronous condition while the request closure runs off the main actor.
        private final class AttachAcknowledgementRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var clients: [TerminalClient] = []

            func record(_ client: TerminalClient) {
                lock.lock()
                clients.append(client)
                lock.unlock()
            }

            func count() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return clients.count
            }

            func lastClient() -> TerminalClient? {
                lock.lock()
                defer { lock.unlock() }
                return clients.last
            }

            func allClients() -> [TerminalClient] {
                lock.lock()
                defer { lock.unlock() }
                return clients
            }
        }

        /// As much of the daemon's attachment bookkeeping as a redial needs to be judged against: a takeover
        /// makes the asking client the owner, and a `.viewer` attach from that owner gives the session back,
        /// which is what makes discarding an unconfirmed attachment a real loss of ownership. Every answer
        /// is stamped later than the last so the reducer never refuses one of these reads as stale.
        private final class SessionOwnershipTracker: @unchecked Sendable {
            /// The device that takes the session over while this client is away.
            static let otherClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:25:00Z")

            private let lock = NSLock()
            private var attaches = 0
            private var takeovers = 0
            private var takeoverAttempts = 0
            private var stamps = 0
            private var ownerClientID: String?
            private var attachedClient: TerminalClient?
            private var failsNextStateRead = false

            /// Records the attach and answers which one of the run it is.
            func recordAttach(_ client: TerminalClient, mode: TerminalAttachmentMode?) -> Int {
                lock.lock()
                defer { lock.unlock() }
                attaches += 1
                attachedClient = client
                if ownerClientID == client.id, mode != .owner { ownerClientID = nil }
                return attaches
            }

            /// Records that a takeover request was sent and answers which one of the run it is. Counted
            /// apart from `recordTakeover`, which is what the daemon applied: a request that failed in
            /// flight is an attempt with no ownership behind it.
            func recordTakeoverAttempt() -> Int {
                lock.lock()
                defer { lock.unlock() }
                takeoverAttempts += 1
                return takeoverAttempts
            }

            func takeoverAttemptCount() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return takeoverAttempts
            }

            func recordTakeover(clientID: String) {
                lock.lock()
                takeovers += 1
                ownerClientID = clientID
                lock.unlock()
            }

            func attachCount() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return attaches
            }

            func takeoverCount() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return takeovers
            }

            func lastAttachedClient() -> TerminalClient? {
                lock.lock()
                defer { lock.unlock() }
                return attachedClient
            }

            /// Fails the next `.state` read, the way a read whose connection drops under it fails.
            func failNextStateRead() {
                lock.lock()
                failsNextStateRead = true
                lock.unlock()
            }

            /// Whether this read is the one the test asked to fail, consuming that request.
            func shouldFailStateRead() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                let shouldFail = failsNextStateRead
                failsNextStateRead = false
                return shouldFail
            }

            /// Hands the session to the other device, the way its own takeover does while this client is
            /// offline. Not a takeover of this client's: `takeoverCount` counts what this client sent.
            func handOverToOtherClient() {
                lock.lock()
                ownerClientID = Self.otherClient.id
                lock.unlock()
            }

            /// Drops the attachment and the ownership held through it, the way stale-client expiry does.
            func expireAttachment() {
                lock.lock()
                attachedClient = nil
                ownerClientID = nil
                lock.unlock()
            }

            func state() -> GhosttyRemoteSessionStatePayload {
                lock.lock()
                let client = attachedClient
                let owner = ownerClientID
                stamps += 1
                let stamp = stamps
                lock.unlock()
                let emittedAt = String(format: "2026-06-04T%02d:%02d:%02dZ", 14 + stamp / 3600, (stamp / 60) % 60, stamp % 60)
                var clients: [TerminalClient] = []
                var attachments: [TerminalAttachment] = []
                if let client {
                    clients.append(client)
                    attachments.append(
                        TerminalAttachment(
                            sessionID: "terminal-session", clientID: client.id, mode: owner == client.id ? .owner : .viewer,
                            attachedAt: "2026-06-04T14:00:00Z"))
                }
                // The other device's attachment, listed only once it owns the session.
                if owner == Self.otherClient.id {
                    clients.append(Self.otherClient)
                    attachments.append(
                        TerminalAttachment(
                            sessionID: "terminal-session", clientID: Self.otherClient.id, mode: .owner, attachedAt: "2026-06-04T14:25:00Z"))
                }
                return TerminalViewerModelTests.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: clients, attachments: attachments), emittedAt: emittedAt)
            }
        }

        /// The daemon a viewer meets when it opens a session another device owns while that session is
        /// still starting. Nothing spends the open's one automatic takeover while the session is not
        /// running, so it is still unspent when the subscription's initial state arrives with this client's
        /// row already swept away -- the moment a loss and the ordinary attempt land on the same payload.
        private final class SweptViewerTracker: @unchecked Sendable {
            /// The device that owns the session throughout, so a takeover sent here is a preemption.
            static let macClient = TerminalClient(
                id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:25:00Z")

            private let lock = NSLock()
            private var attaches = 0
            private var takeovers = 0

            func recordAttach() -> Int {
                lock.lock()
                defer { lock.unlock() }
                attaches += 1
                return attaches
            }

            func recordTakeover() {
                lock.lock()
                takeovers += 1
                lock.unlock()
            }

            func attachCount() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return attaches
            }

            func takeoverCount() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return takeovers
            }

            /// The session as the daemon reports it: the Mac's ownership always, and this viewer's row
            /// whenever it holds one.
            static func state(client: TerminalClient?, state: TerminalSessionState, emittedAt: String) -> GhosttyRemoteSessionStatePayload {
                var clients = [macClient]
                var attachments = [
                    TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:25:00Z")
                ]
                if let client {
                    clients.append(client)
                    attachments.append(
                        TerminalAttachment(sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:23:30Z"))
                }
                return TerminalViewerModelTests.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: clients, attachments: attachments), emittedAt: emittedAt,
                    state: state)
            }
        }

        /// Answers a `SweptViewerTracker`'s session: the open's attach is acknowledged while the session is
        /// still starting, and every attach after it -- the one a reported loss sends -- is held until the
        /// test releases it, which is the window this viewer spends detached with its reclaim unsettled.
        private struct SweptViewerRequestTransport: SpacesDeviceAPIRequestTransport {
            let tracker: SweptViewerTracker
            let reattachGate: ReclaimTakeoverGate

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .terminalControl(let payload) = request.command {
                    switch payload.action {
                    case .attach:
                        guard let client = payload.client else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                        guard tracker.recordAttach() > 1 else {
                            return TerminalViewerModelTests.terminalStateResponse(
                                SweptViewerTracker.state(client: client, state: .starting, emittedAt: "2026-06-04T14:23:30Z"))
                        }
                        await reattachGate.markStarted()
                        await reattachGate.waitForRelease()
                        return TerminalViewerModelTests.terminalStateResponse(
                            SweptViewerTracker.state(client: client, state: .running, emittedAt: "2026-06-04T14:27:00Z"))
                    case .takeover:
                        tracker.recordTakeover()
                        return SpacesDeviceAPIResponse(ok: true, message: "ok")
                    default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                    }
                }
                if case .state = request.command {
                    // The open's bootstrap read, answered before the session started running: a running one
                    // would spend the open's automatic takeover before the loss below ever arrives.
                    return TerminalViewerModelTests.terminalStateResponse(
                        SweptViewerTracker.state(client: nil, state: .starting, emittedAt: "2026-06-04T14:23:35Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// The two shapes an acknowledgement takes when the daemon cannot name the attachment it made.
        private enum UnnamedAttachAcknowledgement {
            case empty
            case sessionWithoutAttachmentSnapshot
        }

        /// Answers attaches, takeovers and `.state` reads out of one `SessionOwnershipTracker`, so a test
        /// driving the stream through `StageTrackerTestBackend` sees the ownership its own requests produced
        /// rather than a fixed script. The tracker is shared rather than owned because the model opens
        /// several command channels and the factory builds one transport for each.
        private struct OwnershipTrackingRequestTransport: SpacesDeviceAPIRequestTransport {
            let ownership: SessionOwnershipTracker
            /// Holds every takeover until the test releases it, so a test can act while one is in flight.
            let takeoverGate: ReclaimTakeoverGate?
            /// Answers every heartbeat the way the daemon answers one from a client whose lease it expired.
            var expiresLease = false
            /// Fails this attach of the run (1-based) the way a command channel dropped under it does.
            var failingAttachIndex: Int?
            /// Times this takeover of the run (1-based) out before it reaches the daemon, so the session
            /// keeps the ownership it had and the caller is told the request never landed.
            var failingTakeoverIndex: Int?
            /// How the daemon answers an attach when it cannot name the attachment it just made: with
            /// nothing but `ok` (its post-control state load is a `try?`), or with the session and no
            /// attachment snapshot at all (its attachment cache could not be reseeded).
            var unnamedAttachAcknowledgement: UnnamedAttachAcknowledgement?

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .terminalControl(let payload) = request.command {
                    switch payload.action {
                    case .attach:
                        guard let client = payload.client else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                        if ownership.recordAttach(client, mode: payload.attachmentMode) == failingAttachIndex {
                            throw SpacesPinnedTLSConnectionError.connectionClosed
                        }
                        switch unnamedAttachAcknowledgement {
                        case .empty: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                        case .sessionWithoutAttachmentSnapshot:
                            return TerminalViewerModelTests.terminalStateResponse(
                                TerminalViewerModelTests.stateWithoutAttachmentSnapshot(emittedAt: "2026-06-04T14:23:31Z"))
                        case nil: return TerminalViewerModelTests.terminalStateResponse(ownership.state())
                        }
                    case .heartbeat where expiresLease: return SpacesDeviceAPIResponse(ok: false, message: "client not found", errorCode: .notFound)
                    case .takeover:
                        guard let clientID = payload.clientID else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                        if ownership.recordTakeoverAttempt() == failingTakeoverIndex { throw SpacesDeviceAPIClientError.requestTimedOut }
                        await takeoverGate?.markStarted()
                        // The daemon applies the takeover and then answers it, so the gate holds the answer
                        // rather than the effect: the ownership is real while the caller is still sending.
                        ownership.recordTakeover(clientID: clientID)
                        await takeoverGate?.waitForRelease()
                        return TerminalViewerModelTests.terminalStateResponse(ownership.state())
                    default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                    }
                }
                if case .state = request.command {
                    if ownership.shouldFailStateRead() { throw SpacesPinnedTLSConnectionError.connectionClosed }
                    return TerminalViewerModelTests.terminalStateResponse(ownership.state())
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Counts the attaches a run sends. `SpacesDeviceAPIRequestTransport.send` runs off the main actor,
        /// so this uses a lock, the same as `ScrollAfterKeyFailureTracker` above.
        private final class AttachRequestTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var attaches = 0

            func recordAttach() {
                lock.lock()
                attaches += 1
                lock.unlock()
            }

            func attachCount() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return attaches
            }
        }

        /// Counts the attaches and answers every `.state` read with a snapshot that lists the client it saw
        /// attach, which is what a read answered before an outage does: it still names an attachment the
        /// lease may since have expired.
        private final class AttachedClientStateRequestTransport: SpacesDeviceAPIRequestTransport, @unchecked Sendable {
            private let tracker: AttachRequestTracker
            private let lock = NSLock()
            private var attachedClient: TerminalClient?

            init(tracker: AttachRequestTracker) { self.tracker = tracker }

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .terminalControl(let payload) = request.command, payload.action == .attach {
                    tracker.recordAttach()
                    if let client = payload.client {
                        lock.lock()
                        attachedClient = client
                        lock.unlock()
                    }
                }
                guard case .state = request.command else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                lock.lock()
                let client = attachedClient
                lock.unlock()
                guard let client else {
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                let attachment = TerminalAttachment(
                    sessionID: "terminal-session", clientID: client.id, mode: .viewer, attachedAt: "2026-06-04T14:23:31Z")
                return TerminalViewerModelTests.terminalStateResponse(
                    TerminalViewerModelTests.runningTerminalState(
                        attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                        emittedAt: "2026-06-04T14:23:31Z"))
            }

            func close() async {}
        }

        /// Answers requests exactly as `StalledStreamRequestTransport` does and counts the attaches, so a
        /// test driving the stream through `StageTrackerTestBackend` can assert how often a run attached.
        private struct AttachCountingRequestTransport: SpacesDeviceAPIRequestTransport {
            let tracker: AttachRequestTracker

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .terminalControl(let payload) = request.command, payload.action == .attach { tracker.recordAttach() }
                if let acknowledgement = TerminalViewerModelTests.attachAcknowledgement(for: request) { return acknowledgement }
                if case .state = request.command {
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Serves the reclaim's takeover with no real network: the first takeover fails with the error the
        /// test supplies, later ones answer with this client owning the session, `.state` reads answer with
        /// whatever the session's ownership currently is, and every subscription is a handle that delivers
        /// nothing. That leaves the paced redial a transient failure hands the reclaim to as the only thing
        /// moving, countable as one subscribe and one further takeover.
        private actor ReclaimTakeoverBackend: SpacesDeviceAPIBackend {
            private let requestTransport: ReclaimTakeoverTransport
            private var subscribes = 0

            init(firstTakeoverFailure: any Error) { requestTransport = ReclaimTakeoverTransport(firstTakeoverFailure: firstTakeoverFailure) }

            nonisolated func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport { requestTransport }

            nonisolated func openSessionStream(
                request: SpacesDeviceAPIRequest, initialEventTimeout: Duration,
                onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
                onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
            ) async throws -> SpacesDeviceAPIStreamHandle {
                await recordSubscribe()
                return SpacesDeviceAPIStreamHandle {}
            }

            nonisolated func takeoverCount() -> Int { requestTransport.takeoverCount() }
            func subscribeCount() -> Int { subscribes }

            /// Polls rather than parking a continuation, so a takeover that never happens fails the
            /// assertion in the test instead of hanging the run.
            func waitForTakeoverCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
                let deadline = ContinuousClock().now + timeout
                while ContinuousClock().now < deadline {
                    if requestTransport.takeoverCount() >= count { return true }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return requestTransport.takeoverCount() >= count
            }

            private func recordSubscribe() { subscribes += 1 }
        }

        /// The request half of `ReclaimTakeoverBackend`, locked for the same reason as
        /// `LostAttachmentRedialTransport`.
        private final class ReclaimTakeoverTransport: SpacesDeviceAPIRequestTransport, @unchecked Sendable {
            private let lock = NSLock()
            private let firstTakeoverFailure: any Error
            private var takeovers = 0
            private var ownerClientID: String?

            init(firstTakeoverFailure: any Error) { self.firstTakeoverFailure = firstTakeoverFailure }

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .terminalControl(let payload) = request.command, payload.action == .takeover, let clientID = payload.clientID {
                    if recordTakeover() == 1 { throw firstTakeoverFailure }
                    markOwned(clientID: clientID)
                    return TerminalViewerModelTests.terminalStateResponse(currentState())
                }
                if case .state = request.command { return TerminalViewerModelTests.terminalStateResponse(currentState()) }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}

            func takeoverCount() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return takeovers
            }

            /// The session as this daemon stand-in holds it: ownerless until a takeover lands, owned by
            /// this client afterwards, which is what lets the redial's bootstrap read drive the retry and
            /// then confirm it.
            private func currentState() -> GhosttyRemoteSessionStatePayload {
                lock.lock()
                let owner = ownerClientID
                lock.unlock()
                guard let owner else {
                    return TerminalViewerModelTests.runningTerminalState(
                        attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:26:30Z")
                }
                let client = TerminalClient(
                    id: owner, kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-04T14:26:30Z")
                let attachment = TerminalAttachment(sessionID: "terminal-session", clientID: owner, mode: .owner, attachedAt: "2026-06-04T14:26:30Z")
                return TerminalViewerModelTests.runningTerminalState(
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]),
                    emittedAt: "2026-06-04T14:26:31Z")
            }

            private func recordTakeover() -> Int {
                lock.lock()
                defer { lock.unlock() }
                takeovers += 1
                return takeovers
            }

            private func markOwned(clientID: String) {
                lock.lock()
                ownerClientID = clientID
                lock.unlock()
            }
        }

        /// The request half of `LostAttachmentRedialBackend`. A lock rather than an actor because the
        /// model opens several command channels and `send` runs off the main actor on all of them, and
        /// because the test reads the attach log synchronously while one attach is still parked inside
        /// `send`.
        private final class LostAttachmentRedialTransport: SpacesDeviceAPIRequestTransport, @unchecked Sendable {
            private let lock = NSLock()
            private var attaches: [TerminalAttachmentMode?] = []
            private var isHeldAttachReleased = false

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .terminalControl(let payload) = request.command, payload.action == .attach {
                    if recordAttach(payload.attachmentMode) == 1 {
                        while !isHeldAttachReleasedNow() { try? await Task.sleep(for: .milliseconds(5)) }
                        // A command-channel connection failure, not a stream failure: the subscription the
                        // viewer is reading output over is a separate connection and stays up, which is
                        // what leaves the client stranded unless the failure arms a redial itself.
                        throw SpacesPinnedTLSConnectionError.connectionClosed
                    }
                }
                if case .state = request.command {
                    // The redial reads state before it resubscribes, and a read that answers `ok` without
                    // terminal state is itself an error the viewer reports, so answer it the way the daemon
                    // would: the session still belongs to the Mac client this viewer lost its owner
                    // attachment to.
                    let macClient = TerminalClient(
                        id: "mac-owner", kind: .local, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:26:00Z")
                    let macOwner = TerminalAttachment(
                        sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:26:00Z")
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner]),
                            emittedAt: "2026-06-04T14:26:10Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}

            func attachModes() -> [TerminalAttachmentMode?] {
                lock.lock()
                defer { lock.unlock() }
                return attaches
            }

            func releaseHeldAttach() {
                lock.lock()
                isHeldAttachReleased = true
                lock.unlock()
            }

            private func recordAttach(_ mode: TerminalAttachmentMode?) -> Int {
                lock.lock()
                defer { lock.unlock() }
                attaches.append(mode)
                return attaches.count
            }

            private func isHeldAttachReleasedNow() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return isHeldAttachReleased
            }
        }

        /// Hands out stream handles the test drives directly (`fireFrame`, `fireDisconnect`) and can be
        /// told to fail the next `openSessionStream` call with a chosen error, so a test can walk the
        /// connection-stage tracker through every transition (the stage 1 grace, the stage 2 jump on
        /// `allCandidatesUnreachable`, back to `.connected` on a frame) deterministically instead of
        /// racing a real network. `streamHost` seeds `SpacesDeviceAPIStreamHandle.host`, the address the
        /// ping-corroboration probe pins to.
        /// Counts `SpacesDeviceAPIStreamHandle.cancel()` calls for handles `StageTrackerTestBackend` hands
        /// out. `cancel()`'s handler is a synchronous, non-isolated `@Sendable` closure (see
        /// `SpacesDeviceAPIStreamHandle.cancelHandler`), so it cannot hop onto the backend's actor to
        /// record itself there; this plain, unsynchronized counter is the same accepted pattern as
        /// `WaiterReleaseBox` above for the same reason.
        private final class StreamHandleCancelTracker: @unchecked Sendable {
            private(set) var cancelCount = 0
            func recordCancel() { cancelCount += 1 }
        }

        /// Backs `ScrollAfterKeyFailureRequestTransport`. Counts land from `send(request:timeout:)`,
        /// which runs off the main actor (inside `TerminalInputSerialQueue`'s detached task), so this
        /// uses a lock rather than the unsynchronized `@unchecked Sendable` counters above.
        private final class ScrollAfterKeyFailureTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var scrollRequestCount = 0

            func recordScrollRequest() {
                lock.lock()
                scrollRequestCount += 1
                lock.unlock()
            }

            func currentScrollRequestCount() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return scrollRequestCount
            }
        }

        private actor StageTrackerTestBackend: SpacesDeviceAPIBackend {
            /// One opened subscription's callbacks, kept per stream rather than as a single "latest"
            /// pair: stage 2 races two dials at once, so a test has to be able to deliver a frame or a
            /// disconnect on the FIRST of them while the second is still open.
            private struct OpenedStream {
                let onEvent: @MainActor (GhosttyRemoteSessionStatePayload) -> Void
                let onDisconnect: @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
            }

            private var subscribeCount = 0
            /// Every stream this backend has opened, in the order it opened them. Index 0 is the first
            /// subscribe of the run, so `fireFrame(onStream:)` and `fireDisconnect(_:onStream:)` address
            /// a stream by its subscribe number (1-based) and the unsuffixed helpers keep addressing the
            /// most recent one.
            private var openedStreams: [OpenedStream] = []
            /// The initial-event budget each `openSessionStream` call was given, in the same order as
            /// `openedStreams`: what a test asserts when it checks that a redial is dialed on a shorter
            /// budget than a cold open.
            private(set) var initialEventTimeouts: [Duration] = []
            private var nextSubscribeError: (any Error)?
            private var pingOutcome: (any Error)?
            private(set) var pingCallCount = 0
            private var holdNextPing = false
            private var heldPingContinuation: CheckedContinuation<(any Error)?, Never>?
            private var allStreamCandidatesFailed = false
            private var deliverInitialFrameBeforeReturningHandle: GhosttyRemoteSessionStatePayload?
            /// Set by `setFailNextSubscribeBeforeReturningHandle`: the next `openSessionStream` call
            /// invokes `onDisconnect` with this failure before it returns its handle, reproducing the
            /// real backend's race where a fast dial failure can report through `onDisconnect` before
            /// `connect()`'s `subscribe()` call has resumed and installed the returned handle onto the
            /// model's `streamHandle`.
            private var failNextSubscribeBeforeReturningHandle: (error: any Error, exhausted: Bool)?
            private let streamHost: String?
            private let transportFactory: @Sendable () -> any SpacesDeviceAPIRequestTransport
            private let cancelTracker = StreamHandleCancelTracker()

            init(
                streamHost: String? = "127.0.0.1",
                transportFactory: @escaping @Sendable () -> any SpacesDeviceAPIRequestTransport = { StalledStreamRequestTransport() }
            ) {
                self.streamHost = streamHost
                self.transportFactory = transportFactory
            }

            nonisolated func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport { transportFactory() }

            nonisolated func openSessionStream(
                request: SpacesDeviceAPIRequest, initialEventTimeout: Duration,
                onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
                onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
            ) async throws -> SpacesDeviceAPIStreamHandle {
                try await recordSubscribe(initialEventTimeout: initialEventTimeout, onEvent: onEvent, onDisconnect: onDisconnect)
            }

            /// Routed exactly like `SpacesDeviceClosureBackend.sendPinnedPing`, but its outcome is set
            /// directly by the test rather than inferred from a shared request handler, since the ping
            /// corroboration tests need independent control over the probe's answer from every other
            /// request this backend serves.
            func sendPinnedPing(request: SpacesDeviceAPIRequest, host: String, timeout: Duration) async -> (any Error)? {
                pingCallCount += 1
                if holdNextPing {
                    holdNextPing = false
                    return await withCheckedContinuation { continuation in heldPingContinuation = continuation }
                }
                return pingOutcome
            }

            func setNextSubscribeError(_ error: (any Error)?) { nextSubscribeError = error }
            func setPingOutcome(_ error: (any Error)?) { pingOutcome = error }

            /// Makes the next `sendPinnedPing` call park instead of answering immediately, so a test can
            /// replace the stream it was probing (see `probedHandle` in
            /// `TerminalViewerModel.startInputTimeoutCorroborationProbe`) before the probe's own answer
            /// comes back, and only then release it with `releaseHeldPing(with:)`.
            func setHoldNextPing(_ hold: Bool) { holdNextPing = hold }

            /// Answers a ping parked by `setHoldNextPing(true)`. A no-op if nothing is held (the caller
            /// waited for `pingCallCount` to confirm the probe actually started before calling this).
            func releaseHeldPing(with error: (any Error)?) {
                heldPingContinuation?.resume(returning: error)
                heldPingContinuation = nil
            }

            /// Drives the verdict `fireDisconnect` stamps onto the current handle's
            /// `dialExhaustedAllCandidates`, mirroring what the real resolver's `noteStreamFailed(host:)`
            /// would return once every candidate has failed a stream dial.
            func setAllStreamCandidatesFailed(_ failed: Bool) { allStreamCandidatesFailed = failed }

            /// Makes the next `openSessionStream` call deliver `payload` through `onEvent`, on the
            /// MainActor, before that call returns its handle -- reproducing the real backend's race,
            /// where the subscription can start delivering frames before `subscribe()` returns to
            /// `connect()`. `connect()` stays suspended for the whole of `recordSubscribe` below, so this
            /// delivery is guaranteed to land (and, through `registerLiveStreamFrame`, settle
            /// `currentStreamDeliveredFrame`) before `connect()`'s own post-subscribe code ever runs.
            func setDeliverInitialFrameBeforeReturningHandle(_ payload: GhosttyRemoteSessionStatePayload?) {
                deliverInitialFrameBeforeReturningHandle = payload
            }

            /// Makes the next `openSessionStream` call invoke `onDisconnect` with a transport-level dial
            /// failure -- carrying `dialExhaustedAllCandidates: exhausted` -- before that call returns its
            /// handle. Modeled on `setDeliverInitialFrameBeforeReturningHandle` above, for the opposite
            /// outcome: reproduces a fast dial failure reporting through `onDisconnect` while `connect()`
            /// is still suspended awaiting `subscribe()`'s own return, i.e. before its handle has been
            /// installed onto the model's `streamHandle`.
            func setFailNextSubscribeBeforeReturningHandle(exhausted: Bool) {
                // `.streamStalled` is transient (`isTransientReconnectError` includes it unconditionally,
                // no message-text match needed) without also being `.allCandidatesUnreachable`, which
                // `handleDisconnect` escalates to stage 2 on its own via `isAllCandidatesUnreachableError`
                // regardless of `dialExhaustedAllCandidates`. Using that case here would make the
                // escalation this fixture exists to prove come from the error's own identity instead of
                // from the `exhausted` verdict carried on the disconnect event, defeating the point of the
                // regression test. `.streamFailed` with an arbitrary message is also the wrong stand-in:
                // only specific substrings ("timed out", "temporarily unavailable") read as transient
                // there, and a real dial refusal would arrive as a POSIX-coded `NWError`, not this case.
                failNextSubscribeBeforeReturningHandle = (error: SpacesDeviceAPIClientError.streamStalled, exhausted: exhausted)
            }

            @discardableResult func waitForSubscribeCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
                let deadline = ContinuousClock().now + timeout
                while ContinuousClock().now < deadline {
                    if subscribeCount >= count { return true }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return subscribeCount >= count
            }

            func currentSubscribeCount() -> Int { subscribeCount }

            @discardableResult func waitForCancelCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
                let deadline = ContinuousClock().now + timeout
                while ContinuousClock().now < deadline {
                    if cancelTracker.cancelCount >= count { return true }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return cancelTracker.cancelCount >= count
            }

            func currentCancelCount() -> Int { cancelTracker.cancelCount }

            @discardableResult func waitForPingCallCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
                let deadline = ContinuousClock().now + timeout
                while ContinuousClock().now < deadline {
                    if pingCallCount >= count { return true }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return pingCallCount >= count
            }

            /// Delivers `payload` on the most recently opened subscription, exactly as a real stream event
            /// would: proof positive to the model that the connection is live.
            func fireFrame(_ payload: GhosttyRemoteSessionStatePayload) async { await fireFrame(payload, onStream: openedStreams.count) }

            /// Delivers `payload` on the `stream`th subscription this backend opened (1-based), so a test
            /// can decide which of two racing dials is the one that reaches the device.
            func fireFrame(_ payload: GhosttyRemoteSessionStatePayload, onStream stream: Int) async {
                guard stream >= 1, stream <= openedStreams.count else { return }
                let handler = openedStreams[stream - 1].onEvent
                await MainActor.run { handler(payload) }
            }

            /// Ends the most recently opened subscription with `error`, exactly as the real liveness watch
            /// or a transport failure would. A non-nil `error` carries `allStreamCandidatesFailed` as the
            /// event's `dialExhaustedAllCandidates` verdict, mirroring
            /// `SpacesDeviceNetworkBackend.openSessionStream` capturing that verdict onto the event it
            /// hands `onDisconnect`; a clean (`nil`) disconnect always reads `false`, since a clean close
            /// proves nothing about the address that was in use.
            func fireDisconnect(_ error: (any Error)?) async { await fireDisconnect(error, onStream: openedStreams.count) }

            /// Ends the `stream`th subscription this backend opened (1-based), so a test can end one of
            /// two racing dials while the other stays open.
            func fireDisconnect(_ error: (any Error)?, onStream stream: Int) async {
                guard stream >= 1, stream <= openedStreams.count else { return }
                let handler = openedStreams[stream - 1].onDisconnect
                let exhausted = allStreamCandidatesFailed
                await MainActor.run { handler(SpacesDeviceAPIStreamDisconnect(error: error, dialExhaustedAllCandidates: error != nil && exhausted)) }
            }

            /// Fires a disconnect exactly like `fireDisconnect`, except the event's
            /// `dialExhaustedAllCandidates` verdict comes directly from `exhaustedOverride` rather than
            /// from `allStreamCandidatesFailed`. Lets a test decouple what the disconnect event carries at
            /// fire time from what `allStreamCandidatesFailed` (the backend's own "live" state, what a
            /// later query would see) reads, proving the model consumes the captured value rather than
            /// re-deriving it afterward.
            func fireDisconnect(_ error: (any Error)?, exhaustedOverride: Bool) async {
                guard let handler = openedStreams.last?.onDisconnect else { return }
                await MainActor.run {
                    handler(SpacesDeviceAPIStreamDisconnect(error: error, dialExhaustedAllCandidates: error != nil && exhaustedOverride))
                }
            }

            private func recordSubscribe(
                initialEventTimeout: Duration, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
                onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
            ) async throws -> SpacesDeviceAPIStreamHandle {
                subscribeCount += 1
                initialEventTimeouts.append(initialEventTimeout)
                if let nextSubscribeError {
                    self.nextSubscribeError = nil
                    throw nextSubscribeError
                }
                openedStreams.append(OpenedStream(onEvent: onEvent, onDisconnect: onDisconnect))
                if let payload = deliverInitialFrameBeforeReturningHandle {
                    deliverInitialFrameBeforeReturningHandle = nil
                    await MainActor.run { onEvent(payload) }
                }
                if let failure = failNextSubscribeBeforeReturningHandle {
                    failNextSubscribeBeforeReturningHandle = nil
                    await MainActor.run {
                        onDisconnect(SpacesDeviceAPIStreamDisconnect(error: failure.error, dialExhaustedAllCandidates: failure.exhausted))
                    }
                }
                return SpacesDeviceAPIStreamHandle(host: streamHost) { [cancelTracker] in cancelTracker.recordCancel() }
            }
        }

        /// Answers `.state` the way the daemon would and records the timeout every `.state` read was
        /// issued with, so a test can assert that a redial into a reported outage asks on a shorter budget
        /// than a cold open does.
        private actor StateTimeoutRecordingRequestTransport: SpacesDeviceAPIRequestTransport {
            private var recordedStateRequestTimeouts: [Duration] = []

            func stateRequestTimeouts() -> [Duration] { recordedStateRequestTimeouts }
            func stateRequestTimeoutCount() -> Int { recordedStateRequestTimeouts.count }

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .state = request.command {
                    recordedStateRequestTimeouts.append(timeout)
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Answers `.state` the way the daemon would (so a reconnect's bootstrap read succeeds), throws
        /// `requestTimedOut` for every `.key` send (so an input send always reaches the corroboration
        /// probe), and answers everything else `ok`.
        private struct InputTimeoutRequestTransport: SpacesDeviceAPIRequestTransport {
            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .state = request.command {
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                if case .terminalControl(let payload) = request.command, payload.action == .key { throw SpacesDeviceAPIClientError.requestTimedOut }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Answers `.state` the way the daemon would, except that while a hold is armed the next read
        /// that asks for the screen parks until `releaseHeldStateRead()` is called, so a test can act on
        /// the model while a failure handler is suspended inside its own recovery read.
        ///
        /// Only a screen-asking read is eligible. The connect bootstrap read asks for none
        /// (`includesRenderUpdate: false`) and runs as a cancellable child of the dial itself, so parking
        /// one would strand the dial rather than the handler under test -- and a parked
        /// `withCheckedContinuation` does not answer cancellation, so it would hang the test outright.
        private actor HeldStateReadRequestTransport: SpacesDeviceAPIRequestTransport {
            private var isHoldArmed = false
            private var heldContinuation: CheckedContinuation<Void, Never>?
            private var heldReadCount = 0

            func armStateReadHold() { isHoldArmed = true }

            @discardableResult func waitForHeldStateRead(timeout: Duration = .seconds(5)) async -> Bool {
                let deadline = ContinuousClock().now + timeout
                while ContinuousClock().now < deadline {
                    if heldReadCount > 0 { return true }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return heldReadCount > 0
            }

            func releaseHeldStateRead() {
                heldContinuation?.resume()
                heldContinuation = nil
            }

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if let acknowledgement = TerminalViewerModelTests.attachAcknowledgement(for: request) { return acknowledgement }
                if case .state(let payload) = request.command {
                    if isHoldArmed, payload.includesRenderUpdate {
                        isHoldArmed = false
                        heldReadCount += 1
                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in heldContinuation = continuation }
                    }
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Answers `.state` the way the daemon would, and stalls the FIRST `.key` send forever (its
        /// continuation is never resumed) so a test can hold the serial input queue occupied behind a
        /// send that never resolves. Every later `.key` send, and every other request, answers `ok`
        /// immediately: only the head-of-queue item is meant to be stuck.
        private actor StallFirstKeySendRequestTransport: SpacesDeviceAPIRequestTransport {
            private var hasStalledFirstKeySend = false

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .state = request.command {
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                if case .terminalControl(let payload) = request.command, payload.action == .key, !hasStalledFirstKeySend {
                    hasStalledFirstKeySend = true
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Answers `.state` the way the daemon would, throws the command channel's racing
        /// `allCandidatesUnreachable` for every `.key` send (so an input send discovers the same
        /// conclusive stage 2 evidence a failed connect would), and answers everything else `ok`.
        private struct InputAllCandidatesUnreachableRequestTransport: SpacesDeviceAPIRequestTransport {
            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .state = request.command {
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                if case .terminalControl(let payload) = request.command, payload.action == .key {
                    throw SpacesDeviceAPIClientError.allCandidatesUnreachable(hosts: ["127.0.0.1"])
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Throws a raw connection-reset error on every key send, including the one
        /// `performRequestUsingInputChannel` retries after rebuilding the command channel, so the
        /// failure reaches `handleInputSendError` exactly as the task describes: "on the retried send".
        /// `POSIXError(.ECONNRESET)` bridges to `NSError` with domain `NSPOSIXErrorDomain`, the same shape
        /// `transientPOSIXErrorCode` reads off a real dropped-socket error.
        private struct InputConnectionResetRequestTransport: SpacesDeviceAPIRequestTransport {
            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .state = request.command {
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                if case .terminalControl(let payload) = request.command, payload.action == .key { throw POSIXError(.ECONNRESET) }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Fails every key send exactly like `InputConnectionResetRequestTransport` (both the immediate
        /// attempt and `performRequestUsingInputChannel`'s 120 ms retry), but also counts every scroll
        /// request that reaches it, so a test can tell a batch `cancelQueuedInputSends()` dropped apart
        /// from one that actually made it to the transport.
        private struct ScrollAfterKeyFailureRequestTransport: SpacesDeviceAPIRequestTransport {
            let tracker: ScrollAfterKeyFailureTracker

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .state = request.command {
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                if case .terminalControl(let payload) = request.command {
                    if payload.action == .key { throw POSIXError(.ECONNRESET) }
                    if payload.action == .scroll { tracker.recordScrollRequest() }
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Throws a lost-route error on every key send, the way an established connection reports the
        /// network going away underneath it. See `InputConnectionResetRequestTransport` for the bridging.
        private struct InputRouteLossRequestTransport: SpacesDeviceAPIRequestTransport {
            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .state = request.command {
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                if case .terminalControl(let payload) = request.command, payload.action == .key { throw POSIXError(.EHOSTUNREACH) }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Answers every key send with a decoded `ok == false` response, the way the daemon reports a busy
        /// terminal engine (`TerminalControlHandling.swift`'s "Timed out waiting for the terminal to accept
        /// the send."). This is not a transport failure: the daemon was reachable enough to decode the
        /// request and answer it, so nothing here is link evidence.
        private struct InputDaemonTimeoutRejectionRequestTransport: SpacesDeviceAPIRequestTransport {
            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if let acknowledgement = TerminalViewerModelTests.attachAcknowledgement(for: request) { return acknowledgement }
                if case .state = request.command {
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                if case .terminalControl(let payload) = request.command, payload.action == .key {
                    return SpacesDeviceAPIResponse(
                        ok: false, message: "Timed out waiting for the terminal to accept the send.", errorCode: .internalError)
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Throws `SpacesDeviceAPIClientError.connectionClosed` on every key send, the way
        /// `readLineAccumulating` reports the peer closing the command connection before answering
        /// (EOF, nothing decoded). Distinct from `InputConnectionResetRequestTransport`'s raw POSIX
        /// `ECONNRESET`: this is the client's own typed transport-failure shape for a clean peer close.
        private struct InputConnectionClosedRequestTransport: SpacesDeviceAPIRequestTransport {
            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if let acknowledgement = TerminalViewerModelTests.attachAcknowledgement(for: request) { return acknowledgement }
                if case .state = request.command {
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                if case .terminalControl(let payload) = request.command, payload.action == .key { throw SpacesDeviceAPIClientError.connectionClosed }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Fails every send of the key `"a"` (with a connection reset, on both the original attempt and
        /// `performRequestUsingInputChannel`'s one retry, so the failure is conclusive rather than
        /// recovered by the retry) and records every OTHER key it is asked to send, so a test can prove a
        /// keystroke enqueued behind "a" never reaches the transport at all, rather than merely reaching
        /// it and then getting a benign response. `StageTrackerTestBackend`'s `transportFactory` hands out
        /// the same shared instance this test constructs, since a fresh transport per subscribe would
        /// lose the recorded state across the redial `sendKey`'s failure triggers.
        private final class InputConnectionResetForSpecificKeyRequestTransport: SpacesDeviceAPIRequestTransport, @unchecked Sendable {
            private let lock = NSLock()
            private var sentKeys: [String] = []

            func sentKeysSoFar() -> [String] { lock.withLock { sentKeys } }

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .state = request.command {
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                if case .terminalControl(let payload) = request.command, payload.action == .key {
                    if payload.key == "a" { throw POSIXError(.ECONNRESET) }
                    lock.withLock { sentKeys.append(payload.key ?? "") }
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Answers `.state` with a running state until the test flips `setAnswerEnded(true)`, then with
        /// the session's ended runtime state, as the daemon would once a redial races the session ending;
        /// everything else answers `ok`. `SpacesDeviceAPIClient` builds one transport per command channel
        /// and keeps it for the model's whole lifetime (see `SpacesDeviceAPIClient.swift`'s
        /// `makeRequestTransport()` call site), and `connect()` itself performs a bootstrap `.state` read
        /// right after every successful subscribe: answering `ended` unconditionally here would make even
        /// that very first bootstrap read look like the session had already ended, never actually
        /// exercising the missing-live-stream recovery this transport exists to prove out.
        private actor EndedStateAfterMissingLiveStreamTransport: SpacesDeviceAPIRequestTransport {
            private var answerEnded = false

            func setAnswerEnded(_ value: Bool) { answerEnded = value }

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .state = request.command {
                    if answerEnded {
                        return TerminalViewerModelTests.terminalStateResponse(
                            TerminalViewerModelTests.runState(
                                childPID: 200, state: .exited, reason: TerminalRemoteSessionStateReason.terminated.rawValue,
                                emittedAt: "2026-06-04T14:24:00Z"))
                    }
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        /// Answers `.state` with a running state until the test flips `setSessionEnded(true)`; from then
        /// on every key send is refused with the daemon's `sessionNotRunning` code and `.state` reports
        /// the ended runtime state, the two answers a daemon gives once the session has ended underneath
        /// an open viewer. Everything else answers `ok`.
        private actor EndedSessionRefusesInputRequestTransport: SpacesDeviceAPIRequestTransport {
            private var sessionEnded = false

            func setSessionEnded(_ value: Bool) { sessionEnded = value }

            func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                if case .state = request.command {
                    if sessionEnded {
                        return TerminalViewerModelTests.terminalStateResponse(
                            TerminalViewerModelTests.runState(
                                childPID: 200, state: .exited, reason: TerminalRemoteSessionStateReason.terminated.rawValue,
                                emittedAt: "2026-06-04T14:24:00Z"))
                    }
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                if sessionEnded, case .terminalControl(let payload) = request.command, payload.action == .key {
                    throw SpacesDeviceAPIClientError.requestFailed("terminal session is not running", code: .sessionNotRunning)
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            func close() async {}
        }

        private final class WaiterReleaseBox: @unchecked Sendable { var released = false }

        /// Every redial bootstraps from a direct `.state` read that continues asynchronously after the
        /// `subscribe` a test waits on, and the fake transports here answer it with an attachment snapshot
        /// that names no owner. That read is newer than the ownership a test asserted through
        /// `configureOwnerInteractiveForTesting`, so once it lands the model is no longer the owner and
        /// a `sendKey` silently no-ops. A test that reasserts ownership after a redial must therefore wait
        /// for the read to land first, or its reassert races the read and loses whenever the transport's
        /// actor hops are slow: that was a real one-in-a-few-runs flake, not load. Observed as the
        /// ownership flip itself, which is exactly the effect the reassert has to come after.
        private func waitForRedialBootstrapToLand(_ model: TerminalViewerModel) async {
            await waitUntil("the redial's bootstrap state read to land (ownership cleared by its ownerless snapshot)") { !model.isOwner }
        }

        /// `waitUntil` for a condition that has to be read off an actor.
        private func waitUntilAsync(_ description: String, timeout: Duration = .seconds(5), _ condition: () async -> Bool) async {
            let deadline = ContinuousClock().now + timeout
            while ContinuousClock().now < deadline {
                if await condition() { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("Timed out waiting for \(description).")
        }

        /// Polls instead of awaiting the condition directly, so a regression that strands a waiter fails
        /// the test itself rather than hanging until XCTest's own timeout kills the whole run.
        private func waitUntil(_ description: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
            let deadline = ContinuousClock().now + timeout
            while ContinuousClock().now < deadline {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("Timed out waiting for \(description).")
        }

        private nonisolated static func outputState(title: String, emittedAt: String) -> GhosttyRemoteSessionStatePayload {
            GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.output.rawValue, emittedAt: emittedAt,
                sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: title,
                workingDirectory: "/tmp/work", outputByteCount: 0)
        }

        /// A payload carrying a full frame, the shape a session exports whenever it includes screen state.
        /// `sessionRevision` and `ownerEpoch` are what the reducer orders an out-of-band response by.
        private nonisolated static func framedState(
            text: String, sessionRevision: UInt64, ownerEpoch: UInt64, emittedAt: String, attachmentSnapshot: TerminalSessionAttachmentSnapshot? = nil
        ) throws -> GhosttyRemoteSessionStatePayload {
            let frame = GhosttyRenderFrame(sessionRevision: sessionRevision, ownerEpoch: ownerEpoch, snapshot: snapshot(text: text))
            return GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: emittedAt,
                sessionStateRevision: sessionRevision, sessionStateFlags: 1, screenStateRevision: sessionRevision, runtimeState: nil,
                attachmentSnapshot: attachmentSnapshot, title: "terminal", workingDirectory: "/tmp/work", outputByteCount: 0,
                renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(frame)))
        }

        /// A payload carrying a delta computed against a baseline this viewer does not hold, so its
        /// reduction fails and asks for a resync. `targetRevision` is the ordering that failure owes.
        private nonisolated static func unappliableDeltaState(baseRevision: UInt64, targetRevision: UInt64, ownerEpoch: UInt64, emittedAt: String)
            throws -> GhosttyRemoteSessionStatePayload
        {
            let delta = GhosttyRenderDeltaFrame(
                baseRevision: baseRevision, targetRevision: targetRevision, ownerEpoch: ownerEpoch, columns: 5, rows: 1, cursorColumn: 0,
                cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF, defaultBackgroundRGB: 0, changedCellCount: 0)
            return GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.output.rawValue, emittedAt: emittedAt,
                sessionStateRevision: targetRevision, sessionStateFlags: 1, screenStateRevision: targetRevision, runtimeState: nil,
                attachmentSnapshot: nil, title: "terminal", workingDirectory: "/tmp/work", outputByteCount: 0,
                renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.delta(delta)))
        }

        private nonisolated static func snapshot(text: String) -> GhosttyTerminalSnapshot {
            let cells = text.unicodeScalars.map { scalar in
                GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0)
            }
            return GhosttyTerminalSnapshot(
                columns: cells.count, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF,
                defaultBackgroundRGB: 0x000000, cells: cells)
        }

        /// A payload carrying runtime state and nothing else, which is what the reducer orders one run
        /// against another by: `childPID` tells the runs apart, `emittedAt` says which is older.
        private nonisolated static func runState(childPID: Int32, state: TerminalSessionState, reason: String, emittedAt: String)
            -> GhosttyRemoteSessionStatePayload
        {
            GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: reason, emittedAt: emittedAt, sessionStateRevision: nil, sessionStateFlags: nil,
                screenStateRevision: nil,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "terminal-session", servicePID: 100, childPID: childPID, state: state, updatedAt: emittedAt), attachmentSnapshot: nil,
                title: "terminal", workingDirectory: "/tmp/work", outputByteCount: 0)
        }

        /// A payload whose attachment snapshot names `clientID` the session's owner, as a takeover response
        /// does.
        private nonisolated static func ownedState(clientID: String, emittedAt: String) -> GhosttyRemoteSessionStatePayload {
            let owner = TerminalClient(
                id: clientID, kind: .remote, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-04T14:23:30Z")
            let attachment = TerminalAttachment(sessionID: "terminal-session", clientID: clientID, mode: .owner, attachedAt: "2026-06-04T14:23:30Z")
            return GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.attachmentState.rawValue, emittedAt: emittedAt,
                sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil, runtimeState: nil,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [owner], attachments: [attachment]), title: "terminal",
                workingDirectory: "/tmp/work", outputByteCount: 0)
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
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-06-04T14:23:30Z",
                sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "terminal-session", servicePID: 100, childPID: 200, state: .running, updatedAt: "2026-06-04T14:23:30Z"),
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [attachedClient], attachments: [attachment]), title: "terminal",
                workingDirectory: "/tmp/work", outputByteCount: 0)
        }

        private nonisolated static func runningTerminalState(
            attachmentSnapshot: TerminalSessionAttachmentSnapshot, emittedAt: String, state: TerminalSessionState = .running
        ) -> GhosttyRemoteSessionStatePayload {
            GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.attachmentState.rawValue, emittedAt: emittedAt,
                sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "terminal-session", servicePID: 100, childPID: 200, state: state, updatedAt: emittedAt),
                attachmentSnapshot: attachmentSnapshot, title: "terminal", workingDirectory: "/tmp/work", outputByteCount: 0)
        }

        /// The answer a daemon gives an attach: the session state it produced, naming the attachment that
        /// attach just made, which is where a client reads which attachment it now holds. A transport that
        /// answers `ok` alone is telling the client its attachment has no name, which is a real but rare
        /// daemon answer (the post-control state load is a `try?`) and sends the client down the read that
        /// names it -- not what a test about input, dialing or reconnect pacing is exercising.
        private nonisolated static func attachAcknowledgement(for request: SpacesDeviceAPIRequest) -> SpacesDeviceAPIResponse? {
            TerminalAttachAcknowledgementFixture.acknowledgement(for: request)
        }

        /// A payload that carries the session and no attachment snapshot at all: what the daemon answers
        /// with when its attachment cache cannot be reseeded, so the answer says nothing about who is
        /// attached rather than saying nobody is.
        private nonisolated static func stateWithoutAttachmentSnapshot(emittedAt: String) -> GhosttyRemoteSessionStatePayload {
            GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: emittedAt,
                sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "terminal-session", servicePID: 100, childPID: 200, state: .running, updatedAt: emittedAt), attachmentSnapshot: nil,
                title: "terminal", workingDirectory: "/tmp/work", outputByteCount: 0)
        }

        /// A payload carrying the session's metadata and no render update: what the daemon answers a
        /// resume's heartbeat with when the client's held frame is already the session's current one.
        private nonisolated static func framelessState(attachmentSnapshot: TerminalSessionAttachmentSnapshot, emittedAt: String)
            -> GhosttyRemoteSessionStatePayload
        {
            GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: emittedAt,
                sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "terminal-session", servicePID: 100, childPID: 200, state: .running, updatedAt: emittedAt),
                attachmentSnapshot: attachmentSnapshot, title: "terminal", workingDirectory: "/tmp/work", outputByteCount: 0)
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

    extension SpacesDeviceAPIRequest {
        fileprivate var terminalLink: String? { if case .resolveTerminalLink(let payload) = command { payload.terminalLink } else { nil } }

        fileprivate var terminalLinkID: String? { if case .readTerminalLinkChunk(let payload) = command { payload.terminalLinkID } else { nil } }

        fileprivate var chunkOffset: Int64? { if case .readTerminalLinkChunk(let payload) = command { payload.offset } else { nil } }
    }

#endif
