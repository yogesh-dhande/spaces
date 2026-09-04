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
                request: SpacesDeviceAPIRequest, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
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
                if case .state = request.command {
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
            let didReadState = try await waitForStateRequestCount(1, recorder: recorder)
            XCTAssertTrue(didReadState, "foreground resume must accept the starting state")
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
                if case .state = request.command {
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
                if case .state = request.command {
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
            let didReadState = try await waitForStateRequestCount(1, recorder: recorder)
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
                if case .state = request.command {
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

            let didReadState = try await waitForStateRequestCount(1, recorder: recorder)
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
                }
                if case .state = request.command {
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
            XCTAssertEqual(
                beforeReadTakeoverCount, 0, "a stream update must not consume foreground ownership intent before its heartbeat and state read")

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
                if case .state = request.command { return await responder.answer() }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            let didStartRead = try await waitForStateRequestCount(1, recorder: recorder)
            XCTAssertTrue(didStartRead, "foreground resume must issue its direct state read")
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
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            let didStartForegroundRead = try await waitForStateRequestCount(1, recorder: recorder)
            XCTAssertTrue(didStartForegroundRead, "foreground resume must have a state read in flight")

            model.stop()
            model.start()
            let didStartReplacementRead = try await waitForStateRequestCount(2, recorder: recorder)
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
                if case .state = request.command {
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
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
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
                    id: clientID, kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-04T14:25:30Z")
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

        func testForegroundResumeConsumesLeaseExpiryStateThatArrivedWhileBackgrounded() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
                if case .state = request.command {
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
                if case .state = request.command { return await stateResponse.current() }
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
            let didReadState = try await waitForStateRequestCount(1, recorder: recorder)
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

        func testForegroundResumePreemptsAnotherActiveOwnerOnce() async throws {
            let recorder = DeviceAPIRequestRecorder()
            let macClient = TerminalClient(
                id: "mac-owner", kind: .localWindow, identity: TerminalClientIdentity(label: "Mac"), connectedAt: "2026-06-04T14:25:00Z")
            let macOwner = TerminalAttachment(sessionID: "terminal-session", clientID: macClient.id, mode: .owner, attachedAt: "2026-06-04T14:25:00Z")
            let macOwnedState = Self.runningTerminalState(
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [macClient], attachments: [macOwner]),
                emittedAt: "2026-06-04T14:25:00Z")
            let bridgeClient = SpacesDeviceAPIClient(settings: settings()) { request in
                await recorder.append(request)
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
            let didReadState = try await waitForStateRequestCount(1, recorder: recorder)
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
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
                return SpacesDeviceAPIResponse(ok: false, message: "state unavailable")
            }
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
            defer { model.stop() }

            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            let didReadState = try await waitForStateRequestCount(1, recorder: recorder)
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
                case "resolveTerminalLink":
                    return SpacesDeviceAPIResponse(ok: false, message: "Terminal link file is not a readable regular file.")
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
            let preview = TerminalLinkPreview(id: "link-1", title: "image.png", kind: .image, content: .quickLook(URL(fileURLWithPath: "/tmp/image.png")))
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
                if case .terminalControl(let payload) = request.command, payload.action == .resize {
                    await resize.waitForFirstResizeThenRelease()
                }
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
            XCTAssertEqual(
                settledRequestCount, 2, "the coalesced report must produce exactly one rerun, not an additional uncoalesced round trip")
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
                if case .terminalControl(let payload) = request.command, payload.action == .takeover {
                    await takeover.waitForReleaseAfterStarting()
                }
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
            XCTAssertTrue(
                model.keepsTerminalInputSurfaceActive, "an owner past its takeover must keep the input surface active while still settling")
            XCTAssertFalse(
                model.isBusy,
                "the stream confirmation must clear the busy takeover presentation on its own, before its own takeover response returns")

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
                id: "mac-window", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces"), connectedAt: "2026-06-04T14:23:30Z")
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
                model.connectionStage, .unreachable,
                "candidate exhaustion describes a different dial, not this stream's own already-proven-live one")
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
                secondProbeStarted,
                "the replacement stream's own input timeout must not be blocked by a stale probe from the stream it replaced")

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
            XCTAssertTrue(redialed, "the 1 s ladder redial armed when the device became unreachable must fire on schedule; typing must not re-arm it further out")
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
        /// branch, which tore the just-redialed stream down through `tearDownStream(reportingLoss:)`, and
        /// `handleDisconnect` (reading `connectionStage == .unreachable`) put the next attempt back on the
        /// ladder, producing a third subscribe roughly 2 s later. Gating on the tracker's stage alone (this
        /// fix) recognizes the in-flight redial as still "link already reported down" and drops the
        /// keystroke without touching it, so the redial that already fired is left alone and no further
        /// subscribe happens.
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
            XCTAssertEqual(model.connectionStage, .unreachable, "the redialed stream has delivered no frame, so the stage must still read unreachable")

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

            // Give the old, buggy path time to run its course: a wrongly torn-down stream would reschedule
            // on the ladder's next delay (2 s) and produce a third subscribe well within this window.
            try await Task.sleep(for: .seconds(2.5))
            let finalSubscribeCount = await backend.currentSubscribeCount()
            XCTAssertEqual(
                finalSubscribeCount, 2,
                "typing into an in-flight redial must not tear it down and force a further reconnect")
            XCTAssertEqual(model.connectionStage, .unreachable)
            XCTAssertNil(model.errorMessage)
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
                tracker.currentScrollRequestCount(), 0,
                "the scroll batch queued behind the failed key send must never reach the transport")

            // The escalation above tears the stream down and arms a redial; wait for its bootstrap read to
            // land and reassert ownership before sending again, exactly like
            // `testTypingDuringAnInFlightUnreachableRedialDoesNotAbortIt` above: otherwise this second
            // `sendScroll` call's own `guard isOwner` would silently no-op it for the wrong reason, and the
            // assertion below would pass without ever exercising the coalescer.
            await waitForRedialBootstrapToLand(model)
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 2)

            await model.sendScroll(horizontal: 0, vertical: 7, scrollMods: 0, pointerPosition: nil)
            await waitUntil("the post-recovery scroll to reach the transport", timeout: .seconds(3)) {
                tracker.currentScrollRequestCount() == 1
            }
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
                request: SpacesDeviceAPIRequest, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
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
            private var subscribeCount = 0
            private var onEvent: (@MainActor (GhosttyRemoteSessionStatePayload) -> Void)?
            private var onDisconnect: (@MainActor (SpacesDeviceAPIStreamDisconnect) -> Void)?
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
                request: SpacesDeviceAPIRequest, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
                onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
            ) async throws -> SpacesDeviceAPIStreamHandle {
                try await recordSubscribe(onEvent: onEvent, onDisconnect: onDisconnect)
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
            func fireFrame(_ payload: GhosttyRemoteSessionStatePayload) async {
                let handler = onEvent
                await MainActor.run { handler?(payload) }
            }

            /// Ends the most recently opened subscription with `error`, exactly as the real liveness watch
            /// or a transport failure would. A non-nil `error` carries `allStreamCandidatesFailed` as the
            /// event's `dialExhaustedAllCandidates` verdict, mirroring
            /// `SpacesDeviceNetworkBackend.openSessionStream` capturing that verdict onto the event it
            /// hands `onDisconnect`; a clean (`nil`) disconnect always reads `false`, since a clean close
            /// proves nothing about the address that was in use.
            func fireDisconnect(_ error: (any Error)?) async {
                let handler = onDisconnect
                let exhausted = allStreamCandidatesFailed
                await MainActor.run {
                    handler?(SpacesDeviceAPIStreamDisconnect(error: error, dialExhaustedAllCandidates: error != nil && exhausted))
                }
            }

            /// Fires a disconnect exactly like `fireDisconnect`, except the event's
            /// `dialExhaustedAllCandidates` verdict comes directly from `exhaustedOverride` rather than
            /// from `allStreamCandidatesFailed`. Lets a test decouple what the disconnect event carries at
            /// fire time from what `allStreamCandidatesFailed` (the backend's own "live" state, what a
            /// later query would see) reads, proving the model consumes the captured value rather than
            /// re-deriving it afterward.
            func fireDisconnect(_ error: (any Error)?, exhaustedOverride: Bool) async {
                let handler = onDisconnect
                await MainActor.run {
                    handler?(SpacesDeviceAPIStreamDisconnect(error: error, dialExhaustedAllCandidates: error != nil && exhaustedOverride))
                }
            }

            private func recordSubscribe(
                onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
                onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
            ) async throws -> SpacesDeviceAPIStreamHandle {
                subscribeCount += 1
                if let nextSubscribeError {
                    self.nextSubscribeError = nil
                    throw nextSubscribeError
                }
                self.onEvent = onEvent
                self.onDisconnect = onDisconnect
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
                if case .terminalControl(let payload) = request.command, payload.action == .key {
                    throw POSIXError(.ECONNRESET)
                }
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
                if case .terminalControl(let payload) = request.command, payload.action == .key {
                    throw POSIXError(.EHOSTUNREACH)
                }
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
                if case .state = request.command {
                    return TerminalViewerModelTests.terminalStateResponse(
                        TerminalViewerModelTests.runningTerminalState(
                            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), emittedAt: "2026-06-04T14:23:31Z"))
                }
                if case .terminalControl(let payload) = request.command, payload.action == .key {
                    throw SpacesDeviceAPIClientError.connectionClosed
                }
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
                id: clientID, kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPhone"), connectedAt: "2026-06-04T14:23:30Z")
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
