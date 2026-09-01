#if canImport(UIKit)
    import Darwin
    import Foundation
    import XCTest
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
                onDisconnect: @escaping @MainActor (Error?) -> Void
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

        private final class WaiterReleaseBox: @unchecked Sendable { var released = false }

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
