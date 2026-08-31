import Dispatch
import Foundation
import spacesdevicecore
import spacesruntimecore
import spacesterminalcore
import workspacecore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
#if canImport(Network)
    import Network
#endif
#if canImport(OpenSSL)
    import OpenSSL
#endif
#if canImport(Security)
    @preconcurrency import Security
#endif

protocol SpacesDevicePairingStoreProtocol: Sendable {
    func issueToken(for clientApp: SpacesDeviceClientApp, presentedToken: String?) throws -> String
    func listDevices() throws -> [SpacesDevicePairedClient]
    func revoke(installationID: String) throws
    func removeAll() throws
    func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws
    func validate(clientApp: SpacesDeviceClientApp) throws
}

extension SpacesDevicePairingStore: SpacesDevicePairingStoreProtocol {}

/// Performance-logging attributes describing a terminal state-stream relay payload.
/// Shared by the Linux and Network device-API server relay paths.
private func deviceAPIStreamRelayAttributes(for data: Data) -> [String: String] {
    var attributes: [String: String] = [
        "payload_bytes": String(data.count), "payload_count": String(data.split(separator: 0x0A, omittingEmptySubsequences: true).count),
    ]
    guard let firstLine = data.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first,
        let payload = try? GhosttyRemoteSessionStateCodec.decodeLine(Data(firstLine))
    else {
        attributes["render_update"] = "unknown"
        return attributes
    }
    attributes["reason"] = payload.reason
    attributes["render_update"] = payload.renderUpdate == nil ? "0" : "1"
    attributes["render_update_bytes"] = String(payload.renderUpdate?.count ?? 0)
    if let update = payload.decodedRenderUpdate {
        attributes["frame_kind"] = update.frameKindMetricValue
        attributes["operation_count"] = String(update.operationCount)
        attributes["changed_cell_count"] = String(update.changedCellCount)
        attributes["scroll_operation_count"] = String(update.scrollOperationCount)
        attributes["base_revision"] = update.baseRevision.map(String.init) ?? "nil"
        attributes["full_frame_fallback_reason"] = update.fallbackReason ?? "none"
    }
    attributes["target_revision"] = payload.screenStateRevision.map(String.init) ?? "nil"
    return attributes
}

extension SpacesDeviceAPICommand {
    fileprivate var isAgentHookCommand: Bool {
        switch self {
        case .agentHooksStatus, .installAgentHooks: true
        default: false
        }
    }

    /// Commands whose work is measured in seconds or longer rather than in database reads. Teardown
    /// (`.archiveWorkspace`, `.deleteProject`) stops every process and terminal in scope, removes git
    /// worktrees, and deletes branches. Run inline on the serial state queue either of these hold up every
    /// other connection's requests — an overview poll issued while one is running waits for the whole
    /// operation and times out as a connection error, and so does the 2-second corroboration `.ping` a
    /// client sends after an input-send timeout, which then tears down a healthy stream. Both transports
    /// divert them to `workspaceTeardownQueue` instead. The client still gets one synchronous response
    /// carrying the full outcome (including the branch-deletion notice and the refreshed overview), so the
    /// request/response contract is unchanged.
    ///
    /// `.stopWorkspace` is also seconds-scale but is not part of this family; see `runsOnWorkspaceStopQueue`
    /// for why it gets its own queue instead. `.runWorkspaceSetup` is likewise seconds-scale and separate;
    /// see `runsOnWorkspaceSetupQueue`. The remaining seconds-scale inline commands are tracked by issue
    /// #503.
    fileprivate var runsOnWorkspaceTeardownQueue: Bool {
        switch self {
        case .archiveWorkspace, .deleteProject: true
        default: false
        }
    }

    /// `.stopWorkspace` runs the user's stop script to completion synchronously
    /// (`Orchestrator.stopWorkspaceUnlocked` calls `runScript`), so a hung stop for one workspace must not
    /// delay an `.archiveWorkspace`/`.deleteProject` for another workspace queued behind it on
    /// `workspaceTeardownQueue`: the same false-failure-then-executes race the setup split closes (see
    /// `runsOnWorkspaceSetupQueue`). Teardown registration happens only at dequeue
    /// (`withTeardownRegistered`), so a delete stuck behind a busy queue looks like a plain failure to the
    /// client and then executes anyway once the queue clears.
    ///
    /// Not merged into `workspaceTeardownQueue` even though archive itself runs the stop path: archive runs
    /// its own stop inline within its own dequeued slot, so sharing a queue would buy it no ordering it
    /// needs, while a hung standalone `.stopWorkspace` for another workspace would only block it. Stop
    /// touches no git state, so there is no git-index serialization reason to share a queue with teardown,
    /// and a race against another command on the same workspace is handled by the orchestrator's own
    /// fail-fast workspace gates.
    fileprivate var runsOnWorkspaceStopQueue: Bool {
        switch self {
        case .stopWorkspace: true
        default: false
        }
    }

    /// `.runWorkspaceSetup` runs the user-authored setup script to completion (`waitUntilExit`, unbounded),
    /// so like teardown it would stall every other connection's requests if left on the serial state queue.
    /// It gets its own serial queue, `workspaceSetupQueue`, rather than sharing `workspaceTeardownQueue`:
    /// the orchestrator deliberately leaves setup ungated so a delete can proceed while setup runs (see
    /// `WorkspaceOrchestrator+Setup.swift`), and a teardown registers its workspace as tearing down
    /// (`withTeardownRegistered`) only after `workspaceTeardownQueue` dequeues its request. Parking
    /// `.archiveWorkspace`/`.deleteProject` behind a running setup on a shared queue would make the delete
    /// wait unregistered, time out client-side, reconcile as a failed delete (the workspace is still
    /// present and not reported as tearing down), and then run anyway once the setup finishes: a false
    /// failure verdict followed by a destructive operation the client believed it had cancelled.
    fileprivate var runsOnWorkspaceSetupQueue: Bool {
        switch self {
        case .runWorkspaceSetup: true
        default: false
        }
    }

    /// `.startWorkspaceCommandSession` synchronously creates a terminal and waits for the injected
    /// terminal launcher to return. Keep that startup wait off the shared state queue so a stalled launch
    /// cannot delay unrelated overview or ping requests. The workspace lifecycle lock inside the
    /// orchestrator still serializes this launch against mutations for the same workspace.
    fileprivate var runsOnWorkspaceTerminalLaunchQueue: Bool {
        switch self {
        case .startWorkspaceCommandSession: true
        default: false
        }
    }

    /// Commands that wait on a terminal session's engine. The control commands each make a synchronous
    /// round trip over that session's control socket and get no answer until the engine drains what it is
    /// already working on; `.state` waits on the same engine from the other side, since a session this
    /// daemon hosts live is read straight out of its core (`liveTerminalSessionStateProvider`, a
    /// `TerminalEngineActor.runSynchronously` export) rather than over the socket. Run inline on the
    /// serial state queue they hold it for that whole wait, so a session saturated by output stalls every
    /// other request on the daemon — including the `.ping` a client sends precisely to ask whether the
    /// link is still alive after an input send timed out. That probe would then time out too and the
    /// client would tear down a healthy stream. Both transports divert these to the target session's own
    /// lane instead (`TerminalControlLaneRegistry`), so a stalled engine holds up only that session.
    fileprivate var runsOnTerminalControlLane: Bool {
        switch self {
        case .terminalControl, .terminalPasteImage, .sendTerminalInput, .state: true
        // round-13 Fix 3: all three review-comment mutations divert here, not just send.
        // `.workspaceReviewCommentsSend` writes to a session's control socket exactly like
        // `.sendTerminalInput` (see `handleWorkspaceReviewCommentsSendRequest`), so it shares that
        // command's stall risk directly. `.workspaceReviewCommentUpsert`/`Delete` don't themselves touch a
        // control socket, but each takes `reviewCommentQueue` for its whole body (see that queue's doc
        // comment) to close a TOCTOU window against a concurrent send — and a send can hold that queue
        // across its own control-socket round trip (up to the client's control-socket timeout, several
        // seconds). Left on the state queue, an upsert/delete blocked behind a slow send would hold that
        // queue's single serial executor for the same duration, stalling every unrelated request — pings,
        // overview, everything — behind one comment save. Diverting them here means only other
        // terminal-control traffic waits, never the state queue.
        case .workspaceReviewCommentUpsert, .workspaceReviewCommentDelete, .workspaceReviewCommentsSend: true
        default: false
        }
    }

    /// File read/write/diff commands all shell out to `git` and touch the filesystem, so like the
    /// other seconds-scale families above they would stall every other connection's requests (including
    /// the corroboration `.ping`) if left on the serial state queue. Both transports divert them to a
    /// serial queue scoped to the request's own workspace (`workspaceGitQueue(for:)`), so a slow diff on one
    /// workspace stalls only that workspace's other requests, not another workspace's or the state queue's.
    /// `.subscribeWorkspaceDiffSignature`, `.subscribeWorkspaceFileSignature`, and
    /// `.subscribeWorkspaceFileListSignature` are not included here: all three hijack the connection
    /// (`hijacksConnection`) before either transport's dispatch chain reaches this check, so none of
    /// them needs a worker-queue divert of its own.
    fileprivate var runsOnWorkspaceGitQueue: Bool {
        switch self {
        case .workspaceFileRead, .workspaceRevisionFileRead, .workspaceFileWrite, .workspaceDiffManifestChunk, .workspaceDiffManifestRelease,
            .workspaceDiffFileChunk,
            .workspaceFileList, .workspaceRefList:
            true
        default: false
        }
    }

    /// `.ping` is the corroboration probe a pane sends after a keystroke's control request missed its
    /// deadline, to ask whether the link is alive before it tears a stream down and shows the
    /// connection-lost banner (`DeviceTerminalSessionStateModel.startLinkCorroborationProbe`). Both
    /// transports answer it without ever entering the shared `spaces.device.api` queue, because the
    /// daemon busy enough to make a keystroke late is exactly the daemon whose shared queue has a backlog
    /// of inline work (`.overview` is a SQLite read plus a per-session filesystem walk, polled several
    /// times a second) — a probe that queues behind that backlog measures the backlog, not the link, and
    /// fails precisely when it is most needed.
    fileprivate var isPingCommand: Bool {
        if case .ping = self { return true }
        return false
    }
}

/// Per-session serial lanes for the engine-blocking terminal commands (`runsOnTerminalControlLane`).
///
/// One session's controls stay ordered among themselves — the client's input sequencer builds its
/// delivery guarantees on top of that order — while different sessions stop serializing behind each
/// other's engine round trips and grid-sized `.state` exports. That cross-session serialization was the
/// entire cost of the single shared control queue it replaces: each queued item can hold a lane for the
/// client's full 5s control deadline, so with N busy sessions a keystroke waited behind up to N other
/// sessions' work, which is why the freeze showed up at roughly five streaming agents and not at one.
///
/// A lane exists only while requests are outstanding on it: it is retained on enqueue and released on
/// completion, and dropped once the count reaches zero. That needs no session-teardown hook and no
/// sweeper — a session that ends without the daemon being told, which is the common case, still leaves
/// nothing behind — and it cannot lose ordering, because a lane is dropped only when there is nothing
/// left to order against, so the next request for that session opens a fresh lane with an empty history.
///
/// What a lane isolates is the Device API's dispatch stage, and only that. Every lane still converges on
/// the process-wide `TerminalEngineActor` (`SpacesdMain`'s `.state` export, `GhosttyEmbeddedSessionHost`'s
/// control sockets), so one session's grid export can still hold another session's request once it is
/// inside the engine. That is a separate, pre-existing property of the engine, tracked by issue #563, and
/// removing the API-layer serialization is worth its own fix regardless: it is what the before/after
/// lane-wait numbers and the ping test that goes red on the unfixed daemon measure.
final class TerminalControlLaneRegistry: @unchecked Sendable {
    /// Where the session-less review-comment upsert/delete mutations run. They deliberately share this
    /// lane while `reviewCommentQueue` serializes them with a send; a send itself carries its target
    /// session id and therefore uses that session's lane.
    private static let unkeyedLaneKey = ""

    private let lock = NSLock()
    private var lanes: [String: (queue: DispatchQueue, outstanding: Int)] = [:]

    /// Returns the lane for `sessionID`, creating it if needed, and counts one outstanding request
    /// against it. Every call must be paired with `release(forSessionID:)`.
    func retain(forSessionID sessionID: String?) -> DispatchQueue {
        let key = sessionID ?? Self.unkeyedLaneKey
        lock.lock()
        defer { lock.unlock() }
        if var lane = lanes[key] {
            lane.outstanding += 1
            lanes[key] = lane
            return lane.queue
        }
        let queue = DispatchQueue(label: "spaces.device.api.terminal-control.\(key)", qos: .userInitiated)
        lanes[key] = (queue: queue, outstanding: 1)
        return queue
    }

    func release(forSessionID sessionID: String?) {
        let key = sessionID ?? Self.unkeyedLaneKey
        lock.lock()
        defer { lock.unlock() }
        guard var lane = lanes[key] else { return }
        lane.outstanding -= 1
        if lane.outstanding <= 0 { lanes.removeValue(forKey: key) } else { lanes[key] = lane }
    }

    var laneCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return lanes.count
    }
}

public final class SpacesDeviceAPIServer: @unchecked Sendable {
    typealias AgentHookStatusLoader = @Sendable () -> [AgentHookStatus]
    typealias AgentHookInstallHandler = @Sendable ([CodingAgent]) throws -> AgentHookInstallOutcome
    /// Exports the current state of a session this daemon hosts live, or nil when it hosts no live core for
    /// that session id (the reader then falls through to the persisted/socket read).
    public typealias LiveTerminalSessionStateProvider = @Sendable (String) -> GhosttyRemoteSessionStatePayload?

    static let pongResponse = SpacesDeviceAPIResponse(ok: true, message: "pong")
    private static let streamRelayReadBufferSize = 256 * 1024
    private static let defaultTerminalLinkTransferAuthorizationTTL: TimeInterval = 10 * 60
    static let terminalPasteImageMaxBytes = 10 * 1024 * 1024
    private static let terminalPasteImageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp",
    ]

    #if canImport(Network) && canImport(Security)
        private struct NetworkShaper: Sendable {
            static let profileEnvironmentKey = "SPACES_DEVICE_API_NETWORK_PROFILE"
            static let rttEnvironmentKey = "SPACES_DEVICE_API_NETWORK_RTT_MS"
            static let bandwidthEnvironmentKey = "SPACES_DEVICE_API_NETWORK_BANDWIDTH_BPS"
            static let chunkEnvironmentKey = "SPACES_DEVICE_API_NETWORK_CHUNK_BYTES"

            let profile: String
            let rttMS: Int
            let bandwidthBPS: Int
            let chunkBytes: Int

            var isEnabled: Bool { profile != "local" && (rttMS > 0 || bandwidthBPS > 0 || chunkBytes > 0) }

            private final class SendChain: @unchecked Sendable {
                private let chunks: [Data]
                private let connection: NWConnection
                private let queue: DispatchQueue
                private let isComplete: Bool
                private let interChunkDelayMicroseconds: @Sendable (Int) -> Int
                private let onSendBegin: @Sendable () -> Void
                private let completion: @Sendable (Error?) -> Void

                init(
                    chunks: [Data], connection: NWConnection, queue: DispatchQueue, isComplete: Bool,
                    interChunkDelayMicroseconds: @escaping @Sendable (Int) -> Int, onSendBegin: @escaping @Sendable () -> Void,
                    completion: @escaping @Sendable (Error?) -> Void
                ) {
                    self.chunks = chunks
                    self.connection = connection
                    self.queue = queue
                    self.isComplete = isComplete
                    self.interChunkDelayMicroseconds = interChunkDelayMicroseconds
                    self.onSendBegin = onSendBegin
                    self.completion = completion
                }

                func send(index: Int) {
                    guard index < chunks.count else {
                        completion(nil)
                        return
                    }
                    let chunk = chunks[index]
                    if index == 0 { onSendBegin() }
                    connection.send(
                        content: chunk, contentContext: .defaultMessage, isComplete: isComplete && index == chunks.count - 1,
                        completion: .contentProcessed { [self] error in
                            if let error {
                                self.completion(error)
                                return
                            }
                            let delayMicroseconds = self.interChunkDelayMicroseconds(chunk.count)
                            if delayMicroseconds <= 0 {
                                self.queue.async { self.send(index: index + 1) }
                            } else {
                                self.queue.asyncAfter(deadline: .now() + .microseconds(delayMicroseconds)) { self.send(index: index + 1) }
                            }
                        })
                }
            }

            init(environment: [String: String] = ProcessInfo.processInfo.environment) {
                let resolvedProfile = environment[Self.profileEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "local"
                profile = resolvedProfile.isEmpty ? "local" : resolvedProfile
                let constrained = profile == "ios-constrained"
                rttMS = Self.intValue(environment[Self.rttEnvironmentKey], fallback: constrained ? 80 : 0)
                bandwidthBPS = Self.intValue(environment[Self.bandwidthEnvironmentKey], fallback: constrained ? 8_000_000 : 0)
                chunkBytes = Self.intValue(environment[Self.chunkEnvironmentKey], fallback: constrained ? 16 * 1024 : 0)
            }

            func send(
                content data: Data, to connection: NWConnection, on queue: DispatchQueue, onSendBegin: @escaping @Sendable () -> Void = {},
                isComplete: Bool = false, applyInitialDelay: Bool = true, applyBandwidthDelay: Bool = true,
                completion: @escaping @Sendable (Error?) -> Void
            ) {
                guard isEnabled, !data.isEmpty else {
                    onSendBegin()
                    connection.send(content: data, contentContext: .defaultMessage, isComplete: isComplete, completion: .contentProcessed(completion))
                    return
                }

                let chunks = chunked(data)
                let initialDelay = DispatchTimeInterval.milliseconds(applyInitialDelay ? max(rttMS / 2, 0) : 0)
                let bandwidthBPS = applyBandwidthDelay ? bandwidthBPS : 0
                let chain = SendChain(
                    chunks: chunks, connection: connection, queue: queue, isComplete: isComplete,
                    interChunkDelayMicroseconds: { byteCount in Self.interChunkDelayMicroseconds(forByteCount: byteCount, bandwidthBPS: bandwidthBPS)
                    }, onSendBegin: onSendBegin, completion: completion)
                queue.asyncAfter(deadline: .now() + initialDelay) { chain.send(index: 0) }
            }

            private func chunked(_ data: Data) -> [Data] {
                let size = chunkBytes > 0 ? chunkBytes : data.count
                guard data.count > size else { return [data] }
                var chunks: [Data] = []
                chunks.reserveCapacity(Int(ceil(Double(data.count) / Double(size))))
                var offset = data.startIndex
                while offset < data.endIndex {
                    let end = data.index(offset, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
                    chunks.append(data[offset..<end])
                    offset = end
                }
                return chunks
            }

            private static func interChunkDelayMicroseconds(forByteCount byteCount: Int, bandwidthBPS: Int) -> Int {
                guard bandwidthBPS > 0, byteCount > 0 else { return 0 }
                let bytesPerSecond = Double(bandwidthBPS) / 8.0
                let seconds = Double(byteCount) / max(bytesPerSecond, 1)
                return max(Int((seconds * 1_000_000).rounded()), 0)
            }

            private static func intValue(_ rawValue: String?, fallback: Int) -> Int {
                guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else { return fallback }
                return max(Int(rawValue) ?? fallback, 0)
            }
        }

        private struct StreamRelay {
            let sessionID: String
            let installationID: String
            let relaySocketFD: Int32
            let relayQueue: DispatchQueue
            let relaySource: DispatchSourceRead
            let heartbeatTimer: DispatchSourceTimer?
            let connection: NWConnection
            let sendSequencer: StreamSendSequencer
            /// Set only for a `subscribeWorkspaceDiffSignature` relay; `closeStreamRelay` uses it to
            /// release that scope's poll-subscriber slot when this relay's connection closes.
            var diffSignatureScope: WorkspaceDiffScope? = nil
            /// Set only for a `subscribeWorkspaceFileSignature` relay; `closeStreamRelay` uses it to
            /// release that scope's poll-subscriber slot when this relay's connection closes. A separate
            /// field from `diffSignatureScope` since the scope types differ (workspace+ref vs. workspace+path).
            var fileSignatureScope: WorkspaceFileScope? = nil
            /// Set only for a `subscribeWorkspaceFileListSignature` relay; `closeStreamRelay` uses it to
            /// release that workspace's poll-subscriber slot when this relay's connection closes.
            var fileListSignatureWorkspaceID: String? = nil
        }

        private final class StreamSendSequencer: @unchecked Sendable {
            typealias Operation = @Sendable (@escaping @Sendable (Error?) -> Void) -> Void

            private let queueKey: DispatchSpecificKey<Void>
            private var pendingOperations: [Operation] = []
            private var isRunning = false

            init(queueKey: DispatchSpecificKey<Void>) { self.queueKey = queueKey }

            func enqueue(_ operation: @escaping Operation) {
                assertOnOwningQueue()
                pendingOperations.append(operation)
                startNextIfNeeded()
            }

            private func startNextIfNeeded() {
                assertOnOwningQueue()
                guard !isRunning, !pendingOperations.isEmpty else { return }
                isRunning = true
                let operation = pendingOperations.removeFirst()
                operation { [weak self] _ in self?.finishCurrent() }
            }

            private func finishCurrent() {
                assertOnOwningQueue()
                isRunning = false
                startNextIfNeeded()
            }

            private func assertOnOwningQueue() {
                precondition(DispatchQueue.getSpecific(key: queueKey) != nil, "StreamSendSequencer must be used on its owning queue.")
            }
        }

        private final class RequestConnection: @unchecked Sendable {
            fileprivate let connection: NWConnection
            private let server: SpacesDeviceAPIServer
            private let peerID: String
            /// This connection's own serial queue. Its `NWConnection` runs on it, so the receive
            /// callbacks, the newline framing, the decode, and the three fields below are confined here
            /// rather than to the shared `spaces.device.api` queue.
            ///
            /// This is what makes `.ping` independent of the daemon's inline request backlog (see
            /// `isPingCommand`). The shared queue is serial and answers `.overview` inline, so while it is
            /// busy a connection started on it cannot even read its bytes off the socket, let alone decide
            /// where to dispatch them; diverting `.ping` to a lane of its own would not have helped,
            /// because the divert decision was itself made on the blocked queue. Everything other than
            /// `.ping` still hops to the shared queue to be authorized and dispatched exactly as before,
            /// so nothing else changes about which queue runs which handler.
            private let connectionQueue: DispatchQueue
            private var buffer = Data()
            /// Set once a subscription or service tunnel takes the connection over, stopping the
            /// newline-delimited JSON read loop so the hijacking path owns all further bytes.
            private var didHijackConnection = false
            private var didReceiveEOF = false
            /// Set when this connection's teardown has run, and read when the listener's accept handler
            /// registers it. Confined to the Device API queue, which is what makes registration and
            /// removal commute: the accept handler starts the connection before enqueueing the
            /// registration (so an accept never waits on the shared queue's inline work), and a
            /// connection that fails or is closed by the client in that window enqueues its teardown
            /// first. That teardown removes nothing — the entry is not there yet — so without this flag
            /// the registration that follows would insert an already-dead connection that nothing ever
            /// removes, and a long-lived daemon would accumulate them along with their retain cycles.
            fileprivate var didTearDownOnDeviceAPIQueue = false

            init(connection: NWConnection, server: SpacesDeviceAPIServer) {
                self.connection = connection
                self.server = server
                peerID = String(describing: connection.endpoint)
                connectionQueue = DispatchQueue(label: "spaces.device.api.connection.\(ObjectIdentifier(connection).hashValue)", qos: .userInitiated)
            }

            func start() {
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.server.trace("request_connection_ready peer=\(self.peerID)")
                        self.receiveNext()
                    case .failed(let error):
                        self.server.trace("request_connection_failed peer=\(self.peerID) error=\(error)")
                        self.tearDown(cancelNetworkConnection: true)
                    case .cancelled:
                        self.server.trace("request_connection_cancelled peer=\(self.peerID)")
                        self.tearDown(cancelNetworkConnection: false)
                    default: break
                    }
                }
                connection.start(queue: connectionQueue)
            }

            /// Marks this connection torn down and runs the server's cleanup, both in one hop onto the
            /// Device API queue so the mark can never land after a registration enqueued behind it.
            /// Idempotent: `.failed` followed by `.cancelled` runs it twice and the second pass finds
            /// nothing left to remove.
            private func tearDown(cancelNetworkConnection: Bool) {
                server.performOnQueue {
                    self.didTearDownOnDeviceAPIQueue = true
                    self.server.closeRequestConnectionAfterNetworkUpdate(
                        connection: self.connection, cancelNetworkConnection: cancelNetworkConnection)
                }
            }

            private func receiveNext() {
                guard !didHijackConnection else { return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
                    guard let self else { return }
                    if let content, !content.isEmpty { self.buffer.append(content) }
                    if let error {
                        self.server.trace("request_receive_error peer=\(self.peerID) error=\(error)")
                        self.connection.cancel()
                        return
                    }
                    if isComplete { self.didReceiveEOF = true }
                    if !self.buffer.isEmpty || self.didReceiveEOF {
                        self.processBufferedLines()
                        return
                    }
                    self.receiveNext()
                }
            }

            private func processBufferedLines() {
                guard !didHijackConnection else { return }
                guard server.acceptingRequests else {
                    connection.cancel()
                    return
                }
                guard let newlineIndex = buffer.firstIndex(of: 0x0A) else {
                    if didReceiveEOF {
                        if !buffer.isEmpty { server.trace("request_incomplete peer=\(peerID) bytes=\(buffer.count)") }
                        connection.cancel()
                    } else {
                        receiveNext()
                    }
                    return
                }

                let line = Data(buffer.prefix(upTo: newlineIndex))
                buffer.removeSubrange(...newlineIndex)
                guard !line.isEmpty else {
                    processBufferedLines()
                    return
                }

                do {
                    let request = try SpacesDeviceAPICodec.decodeRequest(line)
                    server.trace(
                        "request_received peer=\(peerID) command=\(request.commandName) session=\(request.sessionID ?? "-") client=\(request.clientID ?? request.clientApp?.installationID ?? "-")"
                    )
                    // The corroboration probe's contract is that a pong proves this daemon decoded the
                    // request and composed an answer, not that TCP connected. It still does: the line is
                    // framed, decoded, and authorized against the pairing store here exactly as it was on
                    // the shared queue, and a rejection is still an answer this daemon wrote. All that
                    // changed is which queue those steps run on.
                    guard !request.command.isPingCommand else {
                        finishRequest(
                            Result {
                                try server.authorize(request)
                                return SpacesDeviceAPIServer.pongResponse
                            })
                        return
                    }
                    // Everything else is authorized and dispatched on the shared Device API queue, which
                    // is where the request handlers and the server state they touch live.
                    if request.command.hijacksConnection { didHijackConnection = true }
                    let residual = request.command.isTunnelCommand ? buffer : Data()
                    server.queue.async { [weak self] in self?.dispatchOnDeviceAPIQueue(request, residual: residual) }
                } catch { finishRequest(.failure(error)) }
            }

            /// Authorizes and routes one request. Runs on the shared Device API queue; the connection's
            /// own queue reads and decodes the request and continues its read loop from `finishRequest`.
            ///
            /// Admission is rechecked here rather than relying on the check the read loop already made:
            /// that one ran on this connection's own queue, and `stop()` / `resetPairingsAndStop()`
            /// publish `acceptingRequests = false` on THIS queue, so a teardown can land in between and
            /// the request would then be served after it. This queue is where that flag is published and
            /// it serializes against the teardown itself, so the check and the work it guards are one
            /// critical section. `.pair` makes the consequence concrete: it skips authorization by
            /// design, so without this it could mint a token into a pairings file a reset had just
            /// emptied.
            private func dispatchOnDeviceAPIQueue(_ request: SpacesDeviceAPIRequest, residual: Data) {
                do {
                    try server.admitOnQueue()
                    try server.authorize(request)
                    guard !request.command.hijacksConnection else {
                        if request.command.isTunnelCommand {
                            // Whatever remains buffered after the request line is pipelined tunnel data;
                            // hand it to the tunnel so those bytes reach the service.
                            server.handleTunnelRequest(request, connection: connection, residual: residual)
                        } else {
                            try server.handleSubscribeRequest(request, connection: connection)
                        }
                        return
                    }
                    // Diverting a command to a worker queue lets a later request from another connection
                    // finish first. That reorders nothing a client can observe: this connection reads one
                    // response before it sends its next request, so its own commands stay ordered, and
                    // requests racing in on separate connections have no ordering guarantee to begin with.
                    if request.command.isAgentHookCommand {
                        server.handleAgentHookRequestAsync(request) { [weak self] result in self?.finishRequest(result) }
                    } else if request.command.runsOnWorkspaceTeardownQueue {
                        server.handleWorkspaceTeardownRequestAsync(request) { [weak self] result in self?.finishRequest(result) }
                    } else if request.command.runsOnWorkspaceStopQueue {
                        server.handleWorkspaceStopRequestAsync(request) { [weak self] result in self?.finishRequest(result) }
                    } else if request.command.runsOnWorkspaceSetupQueue {
                        server.handleWorkspaceSetupRequestAsync(request) { [weak self] result in self?.finishRequest(result) }
                    } else if request.command.runsOnWorkspaceTerminalLaunchQueue {
                        server.handleStartWorkspaceCommandSessionAsync(request) { [weak self] result in self?.finishRequest(result) }
                    } else if request.command.runsOnTerminalControlLane {
                        server.handleTerminalControlRequestAsync(request) { [weak self] result in self?.finishRequest(result) }
                    } else if request.command.runsOnWorkspaceGitQueue {
                        server.handleWorkspaceGitRequestAsync(request) { [weak self] result in self?.finishRequest(result) }
                    } else {
                        finishRequest(Result { try server.handleRequest(request, peerID: peerID) })
                    }
                } catch { finishRequest(.failure(error)) }
            }

            /// Sends one request result, then either resumes the reusable request session or closes it
            /// after a thrown request error. Called from whichever queue produced the result — this
            /// connection's own queue for `.ping`, the Device API queue for everything else, including
            /// completions handed back from the worker queues — and only touches the connection, so it
            /// needs no particular queue itself. The send is issued on `connectionQueue` so its
            /// completion, which resumes the read loop, lands back where the connection's state lives.
            private func finishRequest(_ result: Result<SpacesDeviceAPIResponse, any Error>) {
                switch result {
                case .success(let response):
                    server.sendResponse(response, to: connection, on: connectionQueue) { [weak self] error in
                        guard let self else { return }
                        if let error {
                            self.server.trace("request_response_error peer=\(self.peerID) error=\(error)")
                            self.connection.cancel()
                            return
                        }
                        self.processBufferedLines()
                    }
                case .failure(let error):
                    server.trace("request_error peer=\(peerID) error=\(String(describing: error).replacingOccurrences(of: "\n", with: "\\n"))")
                    let response = SpacesDeviceAPIServer.failureResponse(for: error)
                    server.sendResponse(response, to: connection, on: connectionQueue) { [weak self] _ in self?.connection.cancel() }
                }
            }
        }
    #endif

    private struct TerminalLinkTransferAuthorization: Sendable {
        let sessionID: String
        let resolvedPath: String
        let expiresAt: Date
    }

    #if os(Linux) && canImport(OpenSSL)
        private struct LinuxSubscription: Sendable {
            let sessionID: String
            let installationID: String
            let subscriptionSocketPath: String
            let controlSocketPath: String
            let clientID: String?
            /// Set only for a `subscribeWorkspaceDiffSignature` relay; `relayLinuxSubscription` uses it to
            /// release that scope's poll-subscriber slot once the relay loop returns.
            var diffSignatureScope: WorkspaceDiffScope? = nil
            /// Set only for a `subscribeWorkspaceFileSignature` relay; `relayLinuxSubscription` uses it to
            /// release that scope's poll-subscriber slot once the relay loop returns.
            var fileSignatureScope: WorkspaceFileScope? = nil
            /// Set only for a `subscribeWorkspaceFileListSignature` relay; `relayLinuxSubscription` uses it
            /// to release that workspace's poll-subscriber slot once the relay loop returns.
            var fileListSignatureWorkspaceID: String? = nil
        }

        private enum LinuxSubscribeAction: Sendable {
            case response(SpacesDeviceAPIResponse)
            case finalPayload(GhosttyRemoteSessionStatePayload)
            case relay(LinuxSubscription)
        }

        private final class LinuxServer: @unchecked Sendable {
            private let host: String
            private let port: Int
            private let identity: TerminalServiceTLSIdentity
            private let server: SpacesDeviceAPIServer
            private let queue: DispatchQueue
            private var acceptSource: DispatchSourceRead?
            private var sslContext: OpaquePointer?
            private let activeConnectionLock = NSLock()
            private var activeConnectionsByFD: [Int32: String] = [:]

            private(set) var listeningPort: Int = 0

            init(host: String, port: Int, identity: TerminalServiceTLSIdentity, server: SpacesDeviceAPIServer, queue: DispatchQueue) {
                self.host = host
                self.port = port
                self.identity = identity
                self.server = server
                self.queue = queue
            }

            func start(timeout: TimeInterval = 5) throws {
                guard (0...Int(UInt16.max)).contains(port) else { throw POSIXError(.EINVAL) }
                let context = try Self.makeSSLContext(identity: identity)
                let socketFD = try Self.makeListenSocket(host: host, port: port)
                try Self.setCloseOnExec(socketFD)
                try Self.setNonBlocking(socketFD)
                sslContext = context
                listeningPort = try Self.resolveListeningPort(socketFD: socketFD)

                let startup = DispatchSemaphore(value: 0)
                let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
                source.setEventHandler { [weak self] in self?.acceptReadyConnections(listenSocketFD: socketFD) }
                // Both the descriptor and the TLS context belong to the dispatch source, not to this
                // object: a cancel handler that reached back through `self` would find it deallocated on a
                // dropped owner and release neither, leaking the descriptor and the `SSL_CTX` heap
                // allocation for the process's lifetime. `context` is captured by value so `SSL_CTX_free`
                // runs unconditionally; `self?.sslContext = nil` afterward is best-effort hygiene for a
                // caller that is still alive.
                //
                // This listener binds a TCP host:port, not a filesystem path, so there is no socket file to
                // remove here.
                source.setCancelHandler { [weak self] in
                    close(socketFD)
                    SSL_CTX_free(context)
                    self?.sslContext = nil
                }
                acceptSource = source
                source.resume()
                startup.signal()
                guard startup.wait(timeout: .now() + timeout) == .success else { throw POSIXError(.ETIMEDOUT) }
            }

            func stop() {
                acceptSource?.cancel()
                acceptSource = nil
                closeActiveConnections(where: { _ in true })
            }

            func closeConnections(forInstallationID installationID: String) { closeActiveConnections { $0 == installationID } }

            private func acceptReadyConnections(listenSocketFD: Int32) {
                while true {
                    let clientFD = accept(listenSocketFD, nil, nil)
                    if clientFD < 0 {
                        if errno == EWOULDBLOCK || errno == EAGAIN { return }
                        return
                    }
                    do {
                        try Self.setCloseOnExec(clientFD)
                        try Self.setBlocking(clientFD)
                        Self.setSocketTimeout(clientFD, seconds: 120)
                        SpacesTCPKeepalive.apply(to: clientFD)
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            guard let self else {
                                close(clientFD)
                                return
                            }
                            do { try self.handleClient(fileDescriptor: clientFD) } catch { self.server.trace("linux_request_error \(error)") }
                        }
                    } catch { close(clientFD) }
                }
            }

            private func handleClient(fileDescriptor: Int32) throws {
                guard let sslContext else {
                    close(fileDescriptor)
                    return
                }
                guard let ssl = SSL_new(sslContext) else {
                    close(fileDescriptor)
                    throw POSIXError(.EIO)
                }
                defer {
                    unregisterActiveConnection(fileDescriptor)
                    SSL_shutdown(ssl)
                    SSL_free(ssl)
                    close(fileDescriptor)
                }

                SSL_set_fd(ssl, fileDescriptor)
                guard SSL_accept(ssl) == 1 else { throw POSIXError(.EACCES) }
                var requestBuffer = Data()
                while true {
                    guard let requestData = try Self.readTLSRequestLine(ssl: ssl, buffer: &requestBuffer) else { return }
                    let requestReceivedUptime = DispatchTime.now().uptimeNanoseconds
                    let request: SpacesDeviceAPIRequest
                    do { request = try SpacesDeviceAPICodec.decodeRequest(requestData) } catch {
                        try Self.writeTLSResponse(
                            try SpacesDeviceAPICodec.encodeResponseLine(
                                .init(ok: false, message: String(describing: error), errorCode: SpacesDeviceAPIServer.errorCode(for: error))),
                            ssl: ssl)
                        return
                    }
                    logRequestPerformance(
                        name: "request_line_received", request: request, emittedUptimeNanoseconds: requestReceivedUptime, count: requestData.count,
                        fileDescriptor: fileDescriptor)

                    if request.command.isSubscriptionCommand {
                        let action = try server.syncOnQueue {
                            try server.admitOnQueue()
                            try server.authorize(request)
                            return try server.prepareLinuxSubscribe(request)
                        }
                        switch action {
                        case .response(let response):
                            let responseLine = try SpacesDeviceAPICodec.encodeResponseLine(response)
                            try writeLoggedTLSResponse(
                                responseLine, ssl: ssl, request: request, responseOK: response.ok, fileDescriptor: fileDescriptor)
                        case .finalPayload(let payload):
                            let payloadLine = try GhosttyRemoteSessionStateCodec.encodeLine(payload)
                            try writeLoggedTLSResponse(payloadLine, ssl: ssl, request: request, responseOK: true, fileDescriptor: fileDescriptor)
                        case .relay(let subscription):
                            registerActiveConnection(fileDescriptor, installationID: subscription.installationID)
                            try server.relayLinuxSubscription(subscription, ssl: ssl)
                        }
                        return
                    }

                    if request.command.isTunnelCommand {
                        guard case .openServiceTunnel(let tunnelRequest) = request.command else { return }
                        let outcome = server.prepareServiceTunnel(request, tunnelRequest: tunnelRequest)
                        switch outcome {
                        case .reject(let response): try Self.writeTLSResponse(try SpacesDeviceAPICodec.encodeResponseLine(response), ssl: ssl)
                        case .ready(let loopbackFD):
                            defer {
                                close(loopbackFD)
                                server.finishServiceTunnel()
                            }
                            try Self.writeTLSResponse(
                                try SpacesDeviceAPICodec.encodeResponseLine(SpacesDeviceAPIResponse(ok: true, message: "Tunnel open.")), ssl: ssl)
                            // Register the client fd so pairing revoke / server stop shut the tunnel down.
                            registerActiveConnection(fileDescriptor, installationID: request.clientApp?.installationID ?? "")
                            // Bytes already buffered past the request line are the pipelining client's
                            // first tunnel bytes; hand them to the splice so they reach the service.
                            let residual = requestBuffer
                            requestBuffer.removeAll(keepingCapacity: false)
                            try SpacesDeviceServiceTunnelSplicer.splice(
                                ssl: ssl, clientFD: fileDescriptor, loopbackFD: loopbackFD, residual: residual)
                        }
                        return
                    }

                    let response: SpacesDeviceAPIResponse
                    var admissionRefused = false
                    do {
                        // Authorization stays on the state queue; only the long or engine-blocking work
                        // moves off it. A command answered from a worker queue can finish after one that
                        // arrived later on another connection, which reorders nothing a client observes:
                        // each connection reads its response before sending its next request, and separate
                        // connections have no ordering guarantee to begin with.
                        //
                        // Admission (`admitOnQueue`) rides in the same hop as authorization, never in one
                        // of its own: two hops would put a teardown between the check and the work. This
                        // transport needs the guard for a reason of its own — a plain request connection
                        // is never handed to `registerActiveConnection` (only subscriptions and tunnels
                        // are), so `stopOnQueue`'s connection sweep does not close its socket and its
                        // thread would otherwise keep serving requests after the server stopped. `.ping`
                        // is exempt because it answers off this queue by design and mutates nothing; a
                        // late pong costs a client one redial.
                        if request.command.isPingCommand {
                            // Answered on this client's own thread, never through `syncOnQueue`: the
                            // corroboration probe must measure the link rather than the shared queue's
                            // inline backlog (see `isPingCommand`). Authorization still runs, on the
                            // pairing store's own lock, so a pong still means this daemon decoded the
                            // request and composed the answer.
                            try server.authorize(request)
                            response = SpacesDeviceAPIServer.pongResponse
                        } else if request.command.isAgentHookCommand {
                            try server.syncOnQueue {
                                try server.admitOnQueue()
                                try server.authorize(request)
                            }
                            response = try server.handleAgentHookRequestOnWorkerQueue(request)
                        } else if request.command.runsOnWorkspaceTeardownQueue {
                            try server.syncOnQueue {
                                try server.admitOnQueue()
                                try server.authorize(request)
                            }
                            response = try server.handleWorkspaceTeardownRequestOnWorkerQueue(request)
                        } else if request.command.runsOnWorkspaceStopQueue {
                            try server.syncOnQueue {
                                try server.admitOnQueue()
                                try server.authorize(request)
                            }
                            response = try server.handleWorkspaceStopRequestOnWorkerQueue(request)
                        } else if request.command.runsOnWorkspaceSetupQueue {
                            try server.syncOnQueue {
                                try server.admitOnQueue()
                                try server.authorize(request)
                            }
                            response = try server.handleWorkspaceSetupRequestOnWorkerQueue(request)
                        } else if request.command.runsOnWorkspaceTerminalLaunchQueue {
                            try server.syncOnQueue {
                                try server.admitOnQueue()
                                try server.authorize(request)
                            }
                            response = try server.handleStartWorkspaceCommandSessionOnWorkerQueue(request)
                        } else if request.command.runsOnTerminalControlLane {
                            try server.syncOnQueue {
                                try server.admitOnQueue()
                                try server.authorize(request)
                            }
                            response = try server.handleTerminalControlRequestOnWorkerQueue(request)
                        } else if request.command.runsOnWorkspaceGitQueue {
                            try server.syncOnQueue {
                                try server.admitOnQueue()
                                try server.authorize(request)
                            }
                            response = try server.handleWorkspaceGitRequestOnWorkerQueue(request)
                        } else {
                            response = try server.syncOnQueue {
                                try server.admitOnQueue()
                                try server.authorize(request)
                                return try server.handleRequest(request, peerID: "linux:\(fileDescriptor)")
                            }
                        }
                    } catch {
                        admissionRefused = error is SpacesDeviceAPIServer.AdmissionRefused
                        response = SpacesDeviceAPIServer.failureResponse(for: error)
                    }
                    let responseLine = try SpacesDeviceAPICodec.encodeResponseLine(response)
                    try writeLoggedTLSResponse(responseLine, ssl: ssl, request: request, responseOK: response.ok, fileDescriptor: fileDescriptor)
                    // A refusal ends the connection, not just this exchange, and returning here runs the
                    // `defer` that closes the socket. `.unauthorized` means the client must re-pair before
                    // anything it sends can be served. An admission refusal means the server has stopped:
                    // this transport never hands a plain request socket to `registerActiveConnection`, so
                    // `stopOnQueue`'s sweep does not close it, and a session client — which reuses one
                    // connection for every request — would keep sending into a stopped server instead of
                    // dialing the replacement listener the supervisor builds.
                    if !response.ok, response.errorCode == .unauthorized || admissionRefused { return }
                }
            }

            private func writeLoggedTLSResponse(
                _ data: Data, ssl: OpaquePointer, request: SpacesDeviceAPIRequest, responseOK: Bool, fileDescriptor: Int32
            ) throws {
                let startedAt = Date()
                let attributes = requestAttributes(request, fileDescriptor: fileDescriptor, extra: ["ok": responseOK ? "1" : "0"])
                if let sessionID = request.sessionID {
                    server.logDeviceAPIPerformance(
                        sessionID: sessionID, name: "request_response_write_begin", count: data.count, attributes: attributes)
                }
                try Self.writeTLSResponse(data, ssl: ssl)
                if let sessionID = request.sessionID {
                    server.logDeviceAPIPerformance(
                        sessionID: sessionID, name: "request_response_write_end", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        count: data.count, attributes: attributes)
                }
            }

            private func logRequestPerformance(
                name: String, request: SpacesDeviceAPIRequest, emittedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
                elapsedMS: Int? = nil, count: Int? = nil, fileDescriptor: Int32
            ) {
                guard let sessionID = request.sessionID else { return }
                server.logDeviceAPIPerformance(
                    sessionID: sessionID, name: name, emittedUptimeNanoseconds: emittedUptimeNanoseconds, elapsedMS: elapsedMS, count: count,
                    attributes: requestAttributes(request, fileDescriptor: fileDescriptor))
            }

            private func requestAttributes(_ request: SpacesDeviceAPIRequest, fileDescriptor: Int32, extra: [String: String] = [:]) -> [String:
                String]
            {
                var attributes: [String: String] = [
                    "command": request.commandName, "peer": "linux:\(fileDescriptor)", "transport": "linux_tls",
                    "client_id": request.clientID ?? request.clientApp?.installationID ?? "nil",
                ]
                for (key, value) in extra { attributes[key] = value }
                return attributes
            }

            private static func makeSSLContext(identity: TerminalServiceTLSIdentity) throws -> OpaquePointer {
                OPENSSL_init_ssl(0, nil)
                guard let method = TLS_server_method(), let context = SSL_CTX_new(method) else { throw POSIXError(.EIO) }
                guard spaces_SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION) == 1 else {
                    SSL_CTX_free(context)
                    throw POSIXError(.EIO)
                }
                guard SSL_CTX_use_certificate_file(context, identity.certificatePath, SSL_FILETYPE_PEM) == 1 else {
                    SSL_CTX_free(context)
                    throw POSIXError(.EIO)
                }
                guard SSL_CTX_use_PrivateKey_file(context, identity.privateKeyPath, SSL_FILETYPE_PEM) == 1 else {
                    SSL_CTX_free(context)
                    throw POSIXError(.EIO)
                }
                guard SSL_CTX_check_private_key(context) == 1 else {
                    SSL_CTX_free(context)
                    throw POSIXError(.EIO)
                }
                return context
            }

            private static func makeListenSocket(host: String, port: Int) throws -> Int32 {
                let socketFD = socket(AF_INET, streamSocketType, 0)
                guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                var yes: Int32 = 1
                setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = in_port_t(UInt16(port).bigEndian)
                if SpacesDeviceAPIDefaults.isWildcardHost(host) {
                    address.sin_addr = in_addr(s_addr: in_addr_t(0))
                } else {
                    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
                        close(socketFD)
                        throw POSIXError(.EADDRNOTAVAIL)
                    }
                }

                let bindResult = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard bindResult == 0 else {
                    let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                    close(socketFD)
                    throw POSIXError(code)
                }
                guard listen(socketFD, 16) == 0 else {
                    let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                    close(socketFD)
                    throw POSIXError(code)
                }
                return socketFD
            }

            private static func resolveListeningPort(socketFD: Int32) throws -> Int {
                var address = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let result = withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in getsockname(socketFD, sockaddrPointer, &length) }
                }
                guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return Int(UInt16(bigEndian: address.sin_port))
            }

            private static func readTLSRequestLine(ssl: OpaquePointer, buffer data: inout Data) throws -> Data? {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    if let newlineIndex = data.firstIndex(of: 0x0A) {
                        let requestData = Data(data.prefix(upTo: newlineIndex))
                        data.removeSubrange(data.startIndex...newlineIndex)
                        return requestData
                    }
                    let count = SSL_read(ssl, &buffer, Int32(buffer.count))
                    if count > 0 {
                        data.append(buffer, count: Int(count))
                        continue
                    }
                    let error = SSL_get_error(ssl, count)
                    if error == SSL_ERROR_ZERO_RETURN {
                        guard !data.isEmpty else { return nil }
                        defer { data.removeAll(keepingCapacity: true) }
                        return data
                    }
                    throw POSIXError(.EIO)
                }
            }

            fileprivate static func writeTLSResponse(_ data: Data, ssl: OpaquePointer) throws {
                try data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    var bytesRemaining = rawBuffer.count
                    var offset = 0
                    while bytesRemaining > 0 {
                        let chunkSize = min(bytesRemaining, Int(Int32.max))
                        let written = SSL_write(ssl, baseAddress.advanced(by: offset), Int32(chunkSize))
                        guard written > 0 else { throw POSIXError(.EIO) }
                        bytesRemaining -= Int(written)
                        offset += Int(written)
                    }
                }
            }

            private func registerActiveConnection(_ fileDescriptor: Int32, installationID: String) {
                activeConnectionLock.lock()
                activeConnectionsByFD[fileDescriptor] = installationID
                activeConnectionLock.unlock()
            }

            private func unregisterActiveConnection(_ fileDescriptor: Int32) {
                activeConnectionLock.lock()
                activeConnectionsByFD.removeValue(forKey: fileDescriptor)
                activeConnectionLock.unlock()
            }

            private func closeActiveConnections(where shouldClose: (String) -> Bool) {
                activeConnectionLock.lock()
                let fileDescriptors = activeConnectionsByFD.filter { shouldClose($0.value) }.map(\.key)
                activeConnectionLock.unlock()
                for fileDescriptor in fileDescriptors {
                    SpacesDeviceAPIServer.shutdownSocket(fileDescriptor, how: SpacesDeviceAPIServer.shutdownReadWrite)
                }
            }

            private static func setNonBlocking(_ fileDescriptor: Int32) throws {
                let currentFlags = fcntl(fileDescriptor, F_GETFL)
                guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }

            private static func setBlocking(_ fileDescriptor: Int32) throws {
                let currentFlags = fcntl(fileDescriptor, F_GETFL)
                guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard fcntl(fileDescriptor, F_SETFL, currentFlags & ~O_NONBLOCK) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }

            private static func setCloseOnExec(_ fileDescriptor: Int32) throws {
                let currentFlags = fcntl(fileDescriptor, F_GETFD)
                guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard fcntl(fileDescriptor, F_SETFD, currentFlags | FD_CLOEXEC) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }

            private static func setSocketTimeout(_ fileDescriptor: Int32, seconds: TimeInterval) {
                var value = timeval(tv_sec: Int(seconds.rounded(.down)), tv_usec: 0)
                setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
            }

            private static var streamSocketType: Int32 { Int32(SOCK_STREAM.rawValue) }
        }
    #endif

    private let host: String
    private let port: Int
    private let identity: TerminalServiceTLSIdentity
    private let pairingCoordinator: SpacesDevicePairingCoordinator
    private let pairingStore: any SpacesDevicePairingStoreProtocol
    private let onPairingSucceeded: (@Sendable (SpacesDeviceClientApp) -> Void)?
    private let builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator?
    private let builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher?
    /// Kills a coding-agent session by its child terminal session id, returning false when the id names
    /// no agent session. Injected because the notify-then-stop flow it performs (`killAgentSession`)
    /// delivers the exited notice through the daemon-owned terminal-send path, which the server cannot
    /// build itself. Nil only in tests or a misconfigured daemon; the `killAgentSession` handler then
    /// reports the endpoint unavailable rather than silently no-op.
    private let agentSessionKiller: (@Sendable (String) throws -> Bool)?
    /// The daemon-side automation operations, routed to the one live automation scheduler. Nil only in
    /// tests or a misconfigured daemon; the automation handlers then report the endpoint unavailable.
    private let automationOperations: AutomationOperations?
    /// Frozen-core restart hook. Invoked for `.requestDaemonRestart`; the daemon performs its
    /// exec-in-place handoff so running terminals, processes, and agents survive the update.
    private let onRestartRequested: (@Sendable () -> Void)?
    /// Exports a session's current state straight from the live in-process core, or nil when this daemon
    /// hosts no live core for that id. Injected because the cores belong to the daemon, not to this server.
    /// Without it every state read — including the one behind each pane attach — makes the daemon connect to
    /// its own session's subscription socket and export a full frame back over that unix round trip.
    private let liveTerminalSessionStateProvider: LiveTerminalSessionStateProvider?
    /// Catalog entries for the daemon's live in-process cores, injected so the overview (and the other
    /// live-session listings below) can cover the write-behind window before a freshly created session's
    /// lifecycle rows commit. Nil in tests or a misconfigured daemon; the merge then falls back to the
    /// DB-only listing, same as before this provider existed.
    private let liveInMemoryTerminalSessionsProvider: (@Sendable () -> [TerminalSessionCatalogEntry])?
    private let overviewLoaderForTesting: (@Sendable (SpacesDeviceClientApp?) throws -> SpacesDeviceOverviewPayload)?
    private let agentHookStatusLoader: AgentHookStatusLoader
    private let agentHookInstallHandler: AgentHookInstallHandler
    /// Login-shell probing and config writes can take seconds. Serialize them independently so they
    /// cannot stall terminal controls, overview requests, or the rest of the Device API state queue.
    private let agentHookQueue = DispatchQueue(label: "spaces.device.api.agent-hooks", qos: .userInitiated)
    /// Teardown (see `runsOnWorkspaceTeardownQueue`) runs seconds or longer: tearing a workspace or project
    /// down stops its processes and terminals, removes git worktrees, and deletes branches. Serialize that
    /// independently of the state queue so it cannot stall every other client's overview polls or
    /// corroboration pings behind it. Serial rather than concurrent because two teardowns in the same
    /// repository would otherwise race on the same git index lock.
    private let workspaceTeardownQueue = DispatchQueue(label: "spaces.device.api.workspace-teardown", qos: .userInitiated)
    /// `.stopWorkspace` (see `runsOnWorkspaceStopQueue`) waits on the user's stop script to completion. It
    /// gets a queue of its own rather than sharing `workspaceTeardownQueue`: a hung or long-running stop
    /// script for one workspace must never hold up an `.archiveWorkspace`/`.deleteProject` request for
    /// another workspace queued behind it. Serial, like the teardown queue, so explicit stops still
    /// serialize among themselves instead of racing the same workspace's stop state.
    private let workspaceStopQueue = DispatchQueue(label: "spaces.device.api.workspace-stop", qos: .userInitiated)
    /// `.runWorkspaceSetup` (see `runsOnWorkspaceSetupQueue`) waits on the user's setup script to
    /// completion. It gets a queue of its own rather than sharing `workspaceTeardownQueue`: a hung or
    /// long-running setup script must never hold up an `.archiveWorkspace`/`.deleteProject` request queued
    /// behind it. Serial, like the teardown queue, so two explicit setup re-runs still serialize among
    /// themselves instead of racing the same workspace's setup state.
    private let workspaceSetupQueue = DispatchQueue(label: "spaces.device.api.workspace-setup", qos: .userInitiated)
    /// Arbitrary command sessions wait synchronously for terminal startup, so run them independently of
    /// the shared request queue while retaining serial ordering among explicit starts.
    private let workspaceTerminalLaunchQueue = DispatchQueue(label: "spaces.device.api.workspace-terminal-launch", qos: .userInitiated)
    /// Terminal input and control round trips block on the target session's engine (see
    /// `runsOnTerminalControlLane`). They run on a serial lane per session (`TerminalControlLaneRegistry`)
    /// so a stalled engine holds up only that session's own controls: never another session's, and never
    /// the state queue that answers overviews and state reads.
    private let terminalControlLanes = TerminalControlLaneRegistry()
    /// Serializes every review-comment mutation — `.workspaceReviewCommentUpsert`, `.workspaceReviewCommentDelete`,
    /// and `.workspaceReviewCommentsSend` — against each other, closing a TOCTOU window `revision` checks alone
    /// cannot: a send validates each comment's `revision` and then, several steps later (session/runtime checks,
    /// the terminal-control-socket write, `markReviewCommentsSent`), archives it. Without this queue an upsert
    /// could land in that window — after the send's revision check reads fresh, before its archive runs — and
    /// the send would still write and archive the text it validated, silently losing the concurrent edit even
    /// though every individual `revision` compare was correct at the instant it ran. round-13 Fix 3: all three
    /// operations also run on a terminal-control lane (see `runsOnTerminalControlLane`) — send because it
    /// shares `.sendTerminalInput`'s control-socket stall risk directly, upsert/delete because a mutation stuck
    /// behind a send holding this queue across that same control-socket round trip must not also hold the
    /// serial state queue hostage, stalling every unrelated request behind one comment save. Each handler
    /// additionally takes this `reviewCommentQueue` for its entire body so nothing here can interleave with
    /// another from validation through archive/write. Nesting `reviewCommentQueue.sync` inside its
    /// terminal-control lane is safe because they are distinct queue objects and nothing on either path
    /// (`SQLiteStore`, `TerminalControlClient.send`, `TerminalSessionPersistence`) dispatches back onto either
    /// queue.
    private let reviewCommentQueue = DispatchQueue(label: "spaces.device.api.review-comments", qos: .userInitiated)
    /// File read/write/diff commands (see `runsOnWorkspaceGitQueue`) shell out to `git` and touch the
    /// filesystem, which can take seconds for a large diff. Serialized per workspace (see
    /// `workspaceGitQueue(for:)`) rather than on one shared queue, so a slow diff on one workspace stalls
    /// only that workspace's other requests, never the state queue's pings/overviews or a different
    /// workspace's file read; same-workspace requests still serialize to preserve write ordering.
    /// Not `private`, only so `@testable` tests can assert an entry was (or was not) minted for a given
    /// workspace id; still module-internal, never part of the public API.
    var workspaceGitQueuesByWorkspaceID: [String: DispatchQueue] = [:]

    /// Returns the serial queue for `workspaceID`'s file read/write/diff commands, creating it on first use.
    /// `queue`-confined (see the property doc above). Workspaces are few and long-lived for the life of a
    /// daemon process, so entries are never evicted — the routing chokepoints below (`handleWorkspaceGitRequestAsync`
    /// / `handleWorkspaceGitRequestOnWorkerQueue`) reject an unresolvable workspace id before it ever reaches
    /// here, which is what keeps this dictionary bounded. Once a real workspace is later deleted, its entry
    /// here still persists for the rest of the daemon's process lifetime: eviction would need plumbing into
    /// the deletion path for a payoff that is not product-visible, since real workspaces over a daemon's
    /// life are bounded by actual usage (hundreds at most, each entry just a label and an idle queue). That
    /// remainder is accepted; the check below closes the unbounded case (arbitrary/spoofed ids), which is
    /// the one with no natural bound.
    private func workspaceGitQueue(for workspaceID: String) -> DispatchQueue {
        if let existing = workspaceGitQueuesByWorkspaceID[workspaceID] { return existing }
        let created = DispatchQueue(label: "spaces.device.api.workspace-git.\(workspaceID)", qos: .userInitiated)
        workspaceGitQueuesByWorkspaceID[workspaceID] = created
        return created
    }

    /// Whether `workspaceID` resolves to a real workspace — the same lookup `resolveWorkspaceDirectory`
    /// makes (`store.workspace(id:)`) — checked once at each git-queue routing chokepoint before that
    /// chokepoint mints or looks up `workspaceID`'s entry in `workspaceGitQueuesByWorkspaceID`. A genuine
    /// store-open/query failure propagates normally (this is not a fallback path); only a clean "no such
    /// row" answers `false`.
    private func workspaceExistsForGitQueueRouting(workspaceID: String) throws -> Bool {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        return try store.workspace(id: workspaceID) != nil
    }

    /// The typed not-found error both `resolveWorkspaceDirectory` (inside the handler) and the git-queue
    /// routing chokepoints (before the handler runs) throw/return for the same condition, so the two stay
    /// worded identically.
    private static func workspaceNotFoundError(workspaceID: String) -> NSError {
        NSError(domain: "SpacesDeviceAPIServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Workspace '\(workspaceID)' was not found."])
    }

    /// The workspace id a workspace file-read/write/diff/file-list/ref-list request targets, used to route
    /// it to its per-workspace serial queue (`workspaceGitQueue(for:)`). `preconditionFailure`s mirror
    /// `handleWorkspaceGitRequest`'s: only these five commands ever reach this accessor.
    private func workspaceGitQueueWorkspaceID(for request: SpacesDeviceAPIRequest) -> String {
        switch request.command {
        case .workspaceFileRead(let payload): return payload.workspaceID
        case .workspaceRevisionFileRead(let payload): return payload.workspaceID
        case .workspaceFileWrite(let payload): return payload.workspaceID
        case .workspaceDiffManifestChunk(let payload): return payload.workspaceID
        case .workspaceDiffManifestRelease(let payload): return payload.workspaceID
        case .workspaceDiffFileChunk(let payload): return payload.workspaceID
        case .workspaceFileList(let payload): return payload.workspaceID
        case .workspaceRefList(let payload): return payload.workspaceID
        default: preconditionFailure("Only workspace file-read/write/diff/file-list/ref-list commands run on a workspace-git queue.")
        }
    }
    /// Subprocess-per-call, `Sendable` git wrapper used by the workspace-git handlers and by diff-signature
    /// polling, both of which run off the serial state queue.
    private let workspaceGitClient: RemoteWorkspaceGitClient
    /// Manifests retain a compact plan; child transfers retain generated patch files. One short TTL is
    /// refreshed on every range so a healthy remote download survives while abandoned generations do not
    /// retain plan memory or private files indefinitely.
    private let workspaceDiffTransfers = WorkspaceDiffTransferStore(ttl: 120)
    /// Test-visible counters prove a generation enumerates once and later ranges reuse one generated patch.
    /// They intentionally expose no transfer ids, manifest ids, or filesystem paths.
    var workspaceDiffManifestSessionActiveCount: Int { workspaceDiffTransfers.activeManifestCount }
    var workspaceDiffManifestSessionCreationCount: Int { workspaceDiffTransfers.manifestCreationCount }
    var workspaceDiffPatchTransferActiveCount: Int { workspaceDiffTransfers.activePatchCount }
    var workspaceDiffPatchTransferCreationCount: Int { workspaceDiffTransfers.patchCreationCount }
    /// Producer + 2s poll timer per subscribed (workspace, ref) scope for `subscribeWorkspaceDiffSignature`,
    /// keyed by `WorkspaceDiffScope`. Entries are `queue`-confined: created on a scope's first subscriber
    /// and removed when its last relay closes (see
    /// `addWorkspaceDiffSignatureSubscriber`/`removeWorkspaceDiffSignatureSubscriber`).
    private var workspaceDiffSignatureSubscriptions: [WorkspaceDiffScope: WorkspaceDiffSignatureSubscription] = [:]
    /// Producer + 2s poll timer per subscribed (workspace, path) scope for `subscribeWorkspaceFileSignature`,
    /// keyed by `WorkspaceFileScope`. Entries are `queue`-confined: created on a scope's first subscriber
    /// and removed when its last relay closes (see
    /// `addWorkspaceFileSignatureSubscriber`/`removeWorkspaceFileSignatureSubscriber`).
    private var workspaceFileSignatureSubscriptions: [WorkspaceFileScope: WorkspaceFileSignatureSubscription] = [:]
    /// Producer + 2s poll timer per subscribed workspace for `subscribeWorkspaceFileListSignature`,
    /// keyed by workspace id. Entries are `queue`-confined: created on a workspace's first subscriber
    /// and removed when its last relay closes.
    private var workspaceFileListSignatureSubscriptions: [String: WorkspaceFileListSignatureSubscription] = [:]
    /// Workspaces whose teardown is running or queued on `workspaceTeardownQueue`, reported on every
    /// overview as `workspaceIDsWithTeardownInFlight`. Guarded by its own lock rather than a queue: it is
    /// written from the teardown queue and read from whichever queue is building an overview, and both
    /// operations are a single set mutation.
    private let workspaceTeardownRegistry = WorkspaceTeardownRegistry()
    /// Serial queue that confines all request dispatch and relay-registry mutation. Internal so the
    /// service-tunnel relay methods (in `SpacesDeviceServiceTunnel.swift`) run on the same queue.
    let queue: DispatchQueue
    #if canImport(Network) && canImport(Security)
        /// Where the `NWListener` runs: accepts and the listener's own state updates, kept off the shared
        /// request queue so a busy daemon still accepts connections (see the accept handler in `start`).
        private let listenerQueue = DispatchQueue(label: "spaces.device.api.listener", qos: .userInitiated)
    #endif
    private let queueKey = DispatchSpecificKey<Void>()
    private let stateLock = NSLock()
    private let terminalLinkTransferAuthorizationTTL: TimeInterval
    private let traceEnabled = ProcessInfo.processInfo.environment["SPACES_DEVICE_API_TRACE"] == "1"
    // Device-overview push (cross-platform): a unix-socket producer that both
    // transports relay, fed by database-change notifications. Owned here so the
    // push logic is shared by the macOS and Linux Device API transports.
    private var overviewStreamServer: DeviceOverviewStreamServer?
    private let overviewStreamQueue = DispatchQueue(label: "spaces.device.overview.stream")
    private var overviewDatabaseChangeObserver: NSObjectProtocol?
    private var overviewDistributedChangeObserver: NSObjectProtocol?
    private var overviewTerminalChangeObserver: NSObjectProtocol?
    private var overviewTerminalDistributedObserver: NSObjectProtocol?
    private var overviewBroadcastScheduled = false

    #if canImport(Network) && canImport(Security)
        private let networkShaper: NetworkShaper
        private var listener: NWListener?
        private var requestConnections: [ObjectIdentifier: RequestConnection] = [:]
        private var streamRelays: [ObjectIdentifier: StreamRelay] = [:]
        private var streamRelaysClosingAfterFinalSend: Set<ObjectIdentifier> = []
        /// Active service tunnels keyed by request connection. Mutated only on `queue`; the relay methods
        /// live in `SpacesDeviceServiceTunnel.swift` (same module) which is why this is internal.
        var tunnelRelays: [ObjectIdentifier: SpacesDeviceServiceTunnelRelay] = [:]
        /// Tunnel dials currently running on their relay queues. Each pending dial holds a
        /// `maxConcurrentServiceTunnels` cap slot so a burst of opens cannot overshoot the cap while
        /// dials are off-queue. Mutated only on `queue`.
        var pendingTunnelDialCount = 0
    #elseif os(Linux) && canImport(OpenSSL)
        private var linuxServer: LinuxServer?
        /// Count of in-flight service tunnels for the concurrent-tunnel cap. Each Linux tunnel owns a
        /// blocking `handleClient` thread rather than a registry entry, so the cap is a counter mutated on
        /// `queue`.
        private var activeServiceTunnelCount = 0
    #endif
    private var terminalLinkTransferAuthorizations: [String: TerminalLinkTransferAuthorization] = [:]
    private var running = false
    /// When the listener entered its waiting state, cleared whenever it reaches a definite state.
    /// Only the `NWListener` transport reports waiting; `SpacesDeviceAPIListenerHealth` turns a wait
    /// that outlasts its grace period into a not-running verdict for the supervisor's health check.
    private var listenerWaitingSince: Date?
    /// Written on the Device API queue but read from each request connection's own queue (see
    /// `RequestConnection.connectionQueue`), so it is lock-guarded rather than queue-confined.
    private var acceptingRequestsStorage = false
    private var acceptingRequests: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return acceptingRequestsStorage
        }
        set {
            stateLock.lock()
            acceptingRequestsStorage = newValue
            stateLock.unlock()
        }
    }

    public init(
        host: String, port: Int, identity: TerminalServiceTLSIdentity,
        pairingCoordinator: SpacesDevicePairingCoordinator = SpacesDevicePairingCoordinator(), pairingStore: SpacesDevicePairingStore? = nil,
        onPairingSucceeded: (@Sendable (SpacesDeviceClientApp) -> Void)? = nil,
        builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator? = nil,
        builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher? = nil,
        agentSessionKiller: (@Sendable (String) throws -> Bool)? = nil, automationOperations: AutomationOperations? = nil,
        onRestartRequested: (@Sendable () -> Void)? = nil
    ) throws {
        self.host = host
        self.port = port
        self.identity = identity
        self.pairingCoordinator = pairingCoordinator
        self.onPairingSucceeded = onPairingSucceeded
        self.builtInTerminalSessionTerminator = builtInTerminalSessionTerminator
        self.builtInTerminalSessionLauncher = builtInTerminalSessionLauncher
        self.agentSessionKiller = agentSessionKiller
        self.automationOperations = automationOperations
        self.onRestartRequested = onRestartRequested
        self.workspaceGitClient = RemoteWorkspaceGitClient()
        liveTerminalSessionStateProvider = nil
        liveInMemoryTerminalSessionsProvider = nil
        overviewLoaderForTesting = nil
        agentHookStatusLoader = { AgentHookInstaller.status() }
        agentHookInstallHandler = { try AgentHookInstaller.install($0) }
        if let pairingStore { self.pairingStore = pairingStore } else { self.pairingStore = try SpacesDevicePairingStore() }
        #if canImport(Network) && canImport(Security)
            networkShaper = NetworkShaper()
        #endif
        terminalLinkTransferAuthorizationTTL = Self.defaultTerminalLinkTransferAuthorizationTTL
        queue = DispatchQueue(label: "spaces.device.api")
        queue.setSpecific(key: queueKey, value: ())
    }

    init(
        host: String, port: Int, identity: TerminalServiceTLSIdentity,
        pairingCoordinator: SpacesDevicePairingCoordinator = SpacesDevicePairingCoordinator(),
        pairingStoreProtocol: any SpacesDevicePairingStoreProtocol, onPairingSucceeded: (@Sendable (SpacesDeviceClientApp) -> Void)? = nil,
        networkEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator? = nil,
        builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher? = nil,
        agentSessionKiller: (@Sendable (String) throws -> Bool)? = nil, automationOperations: AutomationOperations? = nil,
        onRestartRequested: (@Sendable () -> Void)? = nil, liveTerminalSessionStateProvider: LiveTerminalSessionStateProvider? = nil,
        liveInMemoryTerminalSessionsProvider: (@Sendable () -> [TerminalSessionCatalogEntry])? = nil,
        terminalLinkTransferAuthorizationTTL: TimeInterval = SpacesDeviceAPIServer.defaultTerminalLinkTransferAuthorizationTTL,
        overviewLoaderForTesting: (@Sendable (SpacesDeviceClientApp?) throws -> SpacesDeviceOverviewPayload)? = nil,
        agentHookStatusLoader: @escaping AgentHookStatusLoader = { AgentHookInstaller.status() },
        agentHookInstallHandler: @escaping AgentHookInstallHandler = { try AgentHookInstaller.install($0) },
        workspaceGitClient: RemoteWorkspaceGitClient = RemoteWorkspaceGitClient()
    ) {
        self.host = host
        self.port = port
        self.identity = identity
        self.pairingCoordinator = pairingCoordinator
        self.pairingStore = pairingStoreProtocol
        self.onPairingSucceeded = onPairingSucceeded
        self.builtInTerminalSessionTerminator = builtInTerminalSessionTerminator
        self.builtInTerminalSessionLauncher = builtInTerminalSessionLauncher
        self.agentSessionKiller = agentSessionKiller
        self.automationOperations = automationOperations
        self.onRestartRequested = onRestartRequested
        self.liveTerminalSessionStateProvider = liveTerminalSessionStateProvider
        self.liveInMemoryTerminalSessionsProvider = liveInMemoryTerminalSessionsProvider
        self.overviewLoaderForTesting = overviewLoaderForTesting
        self.agentHookStatusLoader = agentHookStatusLoader
        self.agentHookInstallHandler = agentHookInstallHandler
        self.workspaceGitClient = workspaceGitClient
        #if canImport(Network) && canImport(Security)
            networkShaper = NetworkShaper(environment: networkEnvironment)
        #endif
        self.terminalLinkTransferAuthorizationTTL = terminalLinkTransferAuthorizationTTL
        queue = DispatchQueue(label: "spaces.device.api")
        queue.setSpecific(key: queueKey, value: ())
    }

    public private(set) var listeningPort: Int = 0

    public var certificateFingerprint: String { identity.certificateFingerprint }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return SpacesDeviceAPIListenerHealth.isRunning(listenerStarted: running, waitingSince: listenerWaitingSince, now: Date())
    }

    /// Live control lanes. Zero once nothing is outstanding, which is what proves the lanes do not
    /// accumulate for sessions that have gone away.
    var terminalControlLaneCountForTesting: Int { terminalControlLanes.laneCountForTesting }

    var requestConnectionCountForTesting: Int {
        #if canImport(Network) && canImport(Security)
            if DispatchQueue.getSpecific(key: queueKey) != nil { return requestConnections.count }
            return queue.sync { requestConnections.count }
        #else
            return 0
        #endif
    }

    func terminalLinkTransferAuthorizationExpirationForTesting(linkID: String) -> Date? {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return terminalLinkTransferAuthorizations[linkID]?.expiresAt }
        return queue.sync { terminalLinkTransferAuthorizations[linkID]?.expiresAt }
    }

    #if canImport(Network) && canImport(Security)
        /// Publishes "this listener is serving" — the port it took and the flags that let it accept — on
        /// the Device API queue. Submitted from the listener's state callback before that callback signals
        /// startup, so it is enqueued ahead of the barrier `start` runs once the signal wakes it.
        private func publishListenerReady(_ listener: NWListener, port readyPort: Int) {
            let listenerID = ObjectIdentifier(listener)
            performOnQueue {
                guard let current = self.listener, ObjectIdentifier(current) == listenerID else { return }
                self.listeningPort = readyPort
                self.acceptingRequests = true
                self.setRunning(true)
            }
        }

        /// Publishes "this listener is no longer serving" on the Device API queue, the queue that owns
        /// `listener` and on which `stopOnQueue` publishes the same flags, so the two orderings cannot
        /// interleave into a stopped server that still reports itself running. Dropping the listener is
        /// part of the publication: it makes the state terminal, so a `.ready` this failure followed can
        /// no longer be re-published by anything holding the same listener, and it is what `start`'s
        /// barrier reads to refuse a listener that died during startup. The listener is cancelled here
        /// because nothing else will: `stopOnQueue` tears down only the listener the server still holds.
        /// The identity guard drops a callback from a listener already torn down or replaced.
        private func publishListenerStopped(_ listener: NWListener) {
            let listenerID = ObjectIdentifier(listener)
            performOnQueue {
                guard let current = self.listener, ObjectIdentifier(current) == listenerID else { return }
                self.acceptingRequests = false
                self.setRunning(false)
                current.cancel()
                self.listener = nil
            }
        }

        /// Starts the waiting clock for a listener that is still the server's, on the queue that owns that
        /// answer. A wait reported before the ready publication lands is recorded all the same and costs
        /// nothing: `SpacesDeviceAPIListenerHealth` reads it only once the listener counts as started, and
        /// the ready publication's `setRunning(true)` clears it.
        private func publishListenerWaiting(_ listener: NWListener) {
            let listenerID = ObjectIdentifier(listener)
            performOnQueue {
                guard let current = self.listener, ObjectIdentifier(current) == listenerID else { return }
                self.markListenerWaiting()
            }
        }

        /// Drops a listener that never reached a serving state `start` could return on. Clearing the
        /// handlers first stops any further callback from this listener, and the identity guard means a
        /// listener some other publication already dropped, or that a later `start` has already replaced,
        /// is left alone.
        private func tearDownStartupListener(_ listener: NWListener) {
            let listenerID = ObjectIdentifier(listener)
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            performOnQueue {
                guard let current = self.listener, ObjectIdentifier(current) == listenerID else { return }
                self.listener = nil
            }
        }
    #endif

    public func start(timeout: TimeInterval = 5) throws {
        #if canImport(Network) && canImport(Security)
            let nwPort = try Self.nwPort(port)
            let tlsOptions = NWProtocolTLS.Options()
            let securityOptions = tlsOptions.securityProtocolOptions
            sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
            sec_protocol_options_set_peer_authentication_required(securityOptions, false)
            guard let secIdentity = sec_identity_create(identity.identity) else { throw TerminalServiceTLSError.identityImportFailed(errSecParam) }
            sec_protocol_options_set_local_identity(securityOptions, secIdentity)
            let parameters = NWParameters(tls: tlsOptions, tcp: SpacesTCPKeepalive.makeTCPOptions())
            if !SpacesDeviceAPIDefaults.isWildcardHost(host) {
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
            }

            let createdListener = try NWListener(using: parameters, on: nwPort)
            let startup = StartupSignal()

            createdListener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                guard self.acceptingRequests else {
                    connection.cancel()
                    return
                }
                self.trace("request_connection_accept peer=\(String(describing: connection.endpoint))")
                let requestConnection = RequestConnection(connection: connection, server: self)
                // Started before it is registered, and on its own queue, so a connection is accepted and
                // read while the shared queue is busy — the corroboration `.ping` arrives on a fresh
                // one-shot connection, and an accept that queued behind inline `.overview` work would
                // defeat answering the ping off that queue. The registry entry, which `stopOnQueue` and
                // the pairing-revoke path read, is still recorded on the shared queue; re-checking
                // `acceptingRequests` there closes the window where a stop lands in between and would
                // otherwise leave this connection unregistered and never cancelled.
                requestConnection.start()
                self.performOnQueue {
                    // Registering a connection whose teardown already ran would leave an entry nothing
                    // removes (see `didTearDownOnDeviceAPIQueue`); registering one that a stop landed on
                    // would leave it outside the sweep `stopOnQueue` already performed. Both checks read
                    // state this queue owns, so the two orderings commute.
                    guard self.acceptingRequests, !requestConnection.didTearDownOnDeviceAPIQueue else {
                        connection.cancel()
                        return
                    }
                    self.requestConnections[ObjectIdentifier(connection)] = requestConnection
                }
            }
            // This handler runs on `listenerQueue`, which is not serialized against `stopOnQueue`, so it
            // publishes no lifecycle state directly: a callback that wrote the flags from here would race
            // a teardown and could leave a stopped server reporting itself running — which the supervisor's
            // health check then never rebuilds — or, after a pairing reset, turn admission back on. Every
            // state instead hops to the Device API queue under a listener-identity guard. Ordering is the
            // point: `listenerQueue` is serial and `performOnQueue` async-enqueues from it (its inline fast
            // path applies only to work already on the Device API queue, which this never is), so the hops
            // land in the order the listener reported them, and `.ready` submits its hop before it signals
            // startup. `start` then fences on that queue before its barrier, so every state emitted up to
            // that point has submitted its hop and the barrier is enqueued behind all of them, which is
            // what lets it read the ordered truth rather than a snapshot. A failure emitted after the fence
            // is genuinely post-startup: it publishes as one, and the supervisor's health loop is what
            // rebuilds on it. Clearing
            // `stateUpdateHandler` in `stopOnQueue` cannot recall a callback the listener queue has already
            // dispatched; nilling `listener` there is what makes such a callback a no-op.
            createdListener.stateUpdateHandler = { [weak self, weak createdListener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let createdListener else { return }
                    // Published before the signal so this hop is enqueued ahead of `start`'s barrier. The
                    // port is read here, on the queue the listener reports from, rather than back in
                    // `start`, so that what the barrier validates is what this state actually carried.
                    self.publishListenerReady(createdListener, port: Int(createdListener.port?.rawValue ?? UInt16(self.port)))
                    startup.signal(.success(()))
                case .failed(let error):
                    if let createdListener { self.publishListenerStopped(createdListener) }
                    startup.signal(.failure(error))
                case .cancelled: if let createdListener { self.publishListenerStopped(createdListener) }
                case .waiting(let error):
                    self.trace("listener_waiting error=\(error)")
                    if let createdListener { self.publishListenerWaiting(createdListener) }
                default: break
                }
            }
            // Recorded on the Device API queue before the listener can call back, so `stopOnQueue` can
            // cancel a listener that is still starting up and so the identity guard above has something
            // to match against from the first callback.
            try syncOnQueue { self.listener = createdListener }
            // The listener runs on a queue of its own for the same reason each request connection does:
            // accepting a connection must not wait on the shared request queue's inline work.
            createdListener.start(queue: listenerQueue)

            if case .failure(let error) = startup.wait(timeout: timeout) ?? .failure(POSIXError(.ETIMEDOUT)) {
                tearDownStartupListener(createdListener)
                throw error
            }
            // Drains `listenerQueue` so every state this listener has already emitted has submitted its
            // hop before the barrier below is enqueued. Without it a `.failed` sitting behind the `.ready`
            // could publish after the barrier passed, and `start` would return success on a listener that
            // is already dead. This cannot deadlock: the state callbacks publish through `performOnQueue`,
            // which async-enqueues from that queue and never waits on this thread.
            listenerQueue.sync {}
            // The barrier. It publishes nothing — every publication already happened on the Device API
            // queue, in the order the listener reported it — and only reads whether this listener is still
            // the server's and still accepting. A `.failed` or `.cancelled` that followed the `.ready` was
            // enqueued ahead of this and dropped the listener; so did a `stop()` or `resetPairingsAndStop()`
            // that landed in the same window. Either way `start` must fail rather than return a success
            // that buries a terminal state, since nothing reports that listener's state again and the
            // supervisor would keep a dead listener alive forever on the strength of this return.
            let isServing = try syncOnQueue { self.listener === createdListener && self.acceptingRequests }
            guard isServing else {
                tearDownStartupListener(createdListener)
                throw POSIXError(.ECANCELED)
            }
        #elseif os(Linux) && canImport(OpenSSL)
            let createdServer = LinuxServer(host: host, port: port, identity: identity, server: self, queue: queue)
            try createdServer.start(timeout: timeout)
            linuxServer = createdServer
            listeningPort = createdServer.listeningPort
            acceptingRequests = true
            setRunning(true)
        #else
            throw POSIXError(.ENOTSUP)
        #endif
        startOverviewStreamServer()
    }

    /// Starts the device-overview producer and observes database changes so each
    /// committed write pushes a fresh overview to subscribed clients. Cross-platform
    /// (POSIX socket + NotificationCenter), with the macOS distributed observer
    /// added so cross-process writes (the CLI sharing this profile) are caught too.
    /// Linux cross-process writes are bridged by spacesd into the same in-process
    /// notification.
    private func startOverviewStreamServer() {
        guard overviewStreamServer == nil else { return }
        let server = DeviceOverviewStreamServer(
            socketPath: (try? TerminalServicePaths.deviceOverviewSocketPath()) ?? "", queue: overviewStreamQueue,
            lineProvider: { [weak self] in
                guard let self, let payload = try? self.loadOverview() else { return nil }
                return try? SpacesDeviceOverviewStreamCodec.encodeLine(payload)
            })
        do { try server.start() } catch {
            trace("overview_stream_server_start_error error=\(error)")
            return
        }
        overviewStreamServer = server
        overviewDatabaseChangeObserver = NotificationCenter.default.addObserver(forName: IPCNotification.databaseDidChange, object: nil, queue: nil) {
            [weak self] _ in self?.scheduleOverviewBroadcast()
        }
        // Terminal runtime/title/exit state lives outside the database, so it does not
        // raise databaseDidChange. Observe the dedicated terminal-overview signal so
        // those changes still push a fresh overview to subscribers.
        overviewTerminalChangeObserver = NotificationCenter.default.addObserver(forName: TerminalOverviewSignal.name, object: nil, queue: nil) {
            [weak self] _ in self?.scheduleOverviewBroadcast()
        }
        #if canImport(Network) && canImport(Security)
            overviewDistributedChangeObserver = DistributedNotificationCenter.default().addObserver(
                forName: IPCNotification.databaseDidChange, object: try? IPCNotification.currentObject(), queue: nil
            ) { [weak self] _ in self?.scheduleOverviewBroadcast() }
            // A terminal session hosted in another process (the app) signals overview
            // changes profile-scoped across processes; catch those here too.
            overviewTerminalDistributedObserver = DistributedNotificationCenter.default().addObserver(
                forName: TerminalOverviewSignal.name, object: try? IPCNotification.currentObject(), queue: nil
            ) { [weak self] _ in self?.scheduleOverviewBroadcast() }
        #endif
    }

    private func stopOverviewStreamServer() {
        if let overviewDatabaseChangeObserver {
            NotificationCenter.default.removeObserver(overviewDatabaseChangeObserver)
            self.overviewDatabaseChangeObserver = nil
        }
        if let overviewTerminalChangeObserver {
            NotificationCenter.default.removeObserver(overviewTerminalChangeObserver)
            self.overviewTerminalChangeObserver = nil
        }
        if let overviewDistributedChangeObserver {
            #if canImport(Network) && canImport(Security)
                DistributedNotificationCenter.default().removeObserver(overviewDistributedChangeObserver)
            #endif
            self.overviewDistributedChangeObserver = nil
        }
        if let overviewTerminalDistributedObserver {
            #if canImport(Network) && canImport(Security)
                DistributedNotificationCenter.default().removeObserver(overviewTerminalDistributedObserver)
            #endif
            self.overviewTerminalDistributedObserver = nil
        }
        overviewStreamServer?.stop()
        overviewStreamServer = nil
    }

    /// Coalesces database-change bursts into one overview rebuild + push.
    private func scheduleOverviewBroadcast() {
        overviewStreamQueue.async { [weak self] in
            guard let self, !self.overviewBroadcastScheduled else { return }
            self.overviewBroadcastScheduled = true
            self.overviewStreamQueue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                guard let self else { return }
                self.overviewBroadcastScheduled = false
                self.overviewStreamServer?.broadcast()
            }
        }
    }

    /// Identifies one (workspace, ref, lastCommit) diff-signature subscription scope. `refName == nil,
    /// lastCommit == false` (or an empty/whitespace `refName`, normalized to `nil` below) is the
    /// uncommitted-changes scope; a non-nil `refName` is a base-branch review scope whose signature
    /// additionally tracks that ref's merge-base with `HEAD`; `lastCommit == true` is the committed-only
    /// scope, whose signature depends only on `HEAD` itself (see
    /// `SpacesDeviceWorkspaceDiffEngine.scopeSignature`). Three subscriptions to the same workspace but
    /// different scopes get independent producers, poll timers, and socket paths, so an uncommitted, a
    /// base-branch-review, and a last-commit pane on the same workspace never share a signature or a
    /// socket.
    struct WorkspaceDiffScope: Hashable, Sendable {
        let workspaceID: String
        let refName: String?
        let lastCommit: Bool

        init(workspaceID: String, refName: String?, lastCommit: Bool = false) {
            self.workspaceID = workspaceID
            // Shares `SpacesDeviceWorkspaceDiffEngine.normalizedRefName` (same target) rather than
            // duplicating the empty/whitespace-to-nil rule: this scope's identity must normalize a ref
            // exactly the way `buildDiffPlanSnapshot`/`scopeSignature` do, or a blank-ref subscription could resolve to
            // the uncommitted scope here while every pull against that same blank ref fails on the engine
            // side with a merge-base error on an empty argument.
            self.refName = SpacesDeviceWorkspaceDiffEngine.normalizedRefName(refName)
            self.lastCommit = lastCommit
        }
    }

    /// A manifest retains one compact changed-file plan for a streaming Editor generation. Its child patch
    /// transfers retain only generated patch files. One store owns both lifetimes so releasing or expiring
    /// a manifest also removes every child file, including a final range retained for replay.
    final class WorkspaceDiffTransferStore: @unchecked Sendable {
        struct ManifestSession {
            let scope: WorkspaceDiffScope
            let workspaceDir: String
            let snapshot: SpacesDeviceWorkspaceDiffEngine.DiffPlanSnapshot
            var expiresAt: Date
        }

        struct CreatedManifest {
            let manifestID: String
            let session: ManifestSession
        }

        struct PatchSession {
            let manifestID: String
            let scope: WorkspaceDiffScope
            let relativePath: String
            let scopeSignature: String
            let file: SpacesDeviceWorkspaceDiffFileMetadata
            let outputURL: URL
            let byteCount: Int64
            /// The final range was sent. Keep this one completed file until another file begins so an
            /// ambiguous EOF response can be replayed byte-for-byte without running git again.
            var isComplete: Bool
            var expiresAt: Date
        }

        enum Lookup<T> {
            case found(T)
            case missing
            case mismatched
        }

        /// One store-owned timer drives expiry through `reapExpired`; it never owns transfer state itself.
        /// Keeping the timer behind this small seam lets the lifecycle contract advance a deterministic test
        /// clock without making production cleanup depend on a wall-clock sleep.
        protocol ExpiryReaper: AnyObject {
            func start(interval: TimeInterval, action: @escaping @Sendable () -> Void)
            func stop()
        }

        final class DispatchExpiryReaper: ExpiryReaper {
            private let queue = DispatchQueue(label: "spaces.workspace-diff-transfer-expiry", qos: .utility)
            private var timer: DispatchSourceTimer?

            func start(interval: TimeInterval, action: @escaping @Sendable () -> Void) {
                precondition(timer == nil, "A workspace diff transfer reaper can only be started once.")
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + interval, repeating: interval)
                timer.setEventHandler(handler: action)
                self.timer = timer
                timer.resume()
            }

            func stop() {
                timer?.setEventHandler {}
                timer?.cancel()
                timer = nil
            }

            deinit { stop() }
        }

        private let lock = NSLock()
        private var manifests: [String: ManifestSession] = [:]
        private var patches: [String: PatchSession] = [:]
        private var createdManifestCount = 0
        private var createdPatchCount = 0
        private let ttl: TimeInterval
        private let clock: @Sendable () -> Date
        private let expiryReaper: any ExpiryReaper
        /// A daemon has only a small number of visible Editor generations. Bounding retained plans prevents
        /// an unresponsive remote client from accumulating arbitrary changed-file metadata before TTL fires.
        private static let maximumActiveManifests = 16

        convenience init(ttl: TimeInterval) { self.init(ttl: ttl, clock: { Date() }, reaper: DispatchExpiryReaper()) }

        /// This initializer is internal for deterministic lifecycle tests. Production always uses the
        /// dispatch reaper above; both paths invoke the same `reapExpired` cleanup operation.
        init(ttl: TimeInterval, clock: @escaping @Sendable () -> Date, reaper: any ExpiryReaper) {
            precondition(ttl > 0, "Workspace diff transfer TTL must be positive.")
            self.ttl = ttl
            self.clock = clock
            expiryReaper = reaper
            // Keep the normal 120s lifetime close to its advertised bound without polling every transfer:
            // one daemon-wide timer reaps at most five seconds after an expiry (and proportionally sooner
            // for short test lifetimes).
            let interval = min(5, max(0.05, ttl / 2))
            reaper.start(interval: interval) { [weak self] in
                guard let self else { return }
                self.reapExpired(now: self.clock())
            }
        }

        deinit {
            expiryReaper.stop()
            removeAll()
        }

        func createManifest(
            scope: WorkspaceDiffScope, workspaceDir: String, snapshot: SpacesDeviceWorkspaceDiffEngine.DiffPlanSnapshot, now: Date = Date()
        ) -> CreatedManifest {
            lock.lock()
            defer { lock.unlock() }
            reapExpiredLocked(now: now)
            while manifests.count >= Self.maximumActiveManifests, let oldest = manifests.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                removeManifestLocked(oldest)
            }
            let manifestID = UUID().uuidString.lowercased()
            let session = ManifestSession(scope: scope, workspaceDir: workspaceDir, snapshot: snapshot, expiresAt: now.addingTimeInterval(ttl))
            manifests[manifestID] = session
            createdManifestCount += 1
            return CreatedManifest(manifestID: manifestID, session: session)
        }

        func lookupManifest(manifestID: String, scope: WorkspaceDiffScope, now: Date = Date()) -> Lookup<ManifestSession> {
            lock.lock()
            defer { lock.unlock() }
            reapExpiredLocked(now: now)
            guard var session = manifests[manifestID] else { return .missing }
            guard session.scope == scope else { return .mismatched }
            session.expiresAt = now.addingTimeInterval(ttl)
            manifests[manifestID] = session
            return .found(session)
        }

        func releaseManifest(manifestID: String, scope: WorkspaceDiffScope, now: Date = Date()) -> Lookup<Void> {
            lock.lock()
            defer { lock.unlock() }
            reapExpiredLocked(now: now)
            guard let session = manifests[manifestID] else { return .missing }
            guard session.scope == scope else { return .mismatched }
            removeManifestLocked(manifestID)
            return .found(())
        }

        func createPatch(
            manifestID: String, scope: WorkspaceDiffScope, relativePath: String, scopeSignature: String, file: SpacesDeviceWorkspaceDiffFileMetadata,
            outputURL: URL, byteCount: Int64, now: Date = Date()
        ) -> String {
            lock.lock()
            defer { lock.unlock() }
            reapExpiredLocked(now: now)
            // A manifest normally streams files serially. Retain its last completed file for a lost EOF
            // response, but drop it before starting the next file so a generation keeps only active files
            // plus at most one completed transfer artifact.
            for transferID in patches.filter({ $0.value.manifestID == manifestID && $0.value.isComplete }).keys { _ = removePatchLocked(transferID) }
            let transferID = UUID().uuidString.lowercased()
            patches[transferID] = PatchSession(
                manifestID: manifestID, scope: scope, relativePath: relativePath, scopeSignature: scopeSignature, file: file, outputURL: outputURL,
                byteCount: byteCount, isComplete: false, expiresAt: now.addingTimeInterval(ttl))
            createdPatchCount += 1
            return transferID
        }

        func lookupPatch(manifestID: String, transferID: String, scope: WorkspaceDiffScope, relativePath: String, now: Date = Date()) -> Lookup<
            PatchSession
        > {
            lock.lock()
            defer { lock.unlock() }
            reapExpiredLocked(now: now)
            guard var manifest = manifests[manifestID] else { return .missing }
            guard manifest.scope == scope else { return .mismatched }
            guard var patch = patches[transferID] else { return .missing }
            guard patch.manifestID == manifestID, patch.scope == scope, patch.relativePath == relativePath else { return .mismatched }
            manifest.expiresAt = now.addingTimeInterval(ttl)
            patch.expiresAt = now.addingTimeInterval(ttl)
            manifests[manifestID] = manifest
            patches[transferID] = patch
            return .found(patch)
        }

        /// Offset-zero requests intentionally carry no transfer ID. If their response was lost, locate the
        /// already-created child by the manifest-bound path so the retry returns the same first range rather
        /// than allocating another active patch file.
        func lookupPatchForInitialRange(manifestID: String, scope: WorkspaceDiffScope, relativePath: String, now: Date = Date()) -> (
            transferID: String, patch: PatchSession
        )? {
            lock.lock()
            defer { lock.unlock() }
            reapExpiredLocked(now: now)
            guard var manifest = manifests[manifestID], manifest.scope == scope,
                let pair = patches.first(where: {
                    $0.value.manifestID == manifestID && $0.value.scope == scope && $0.value.relativePath == relativePath
                })
            else { return nil }
            var patch = pair.value
            manifest.expiresAt = now.addingTimeInterval(ttl)
            patch.expiresAt = now.addingTimeInterval(ttl)
            manifests[manifestID] = manifest
            patches[pair.key] = patch
            return (pair.key, patch)
        }

        @discardableResult func removePatch(transferID: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return removePatchLocked(transferID)
        }

        /// Marks the final range as replayable. The patch file still belongs to its manifest and is removed
        /// by the next file, explicit cancellation/release, TTL, or daemon shutdown.
        func markPatchComplete(transferID: String, now: Date = Date()) {
            lock.lock()
            defer { lock.unlock() }
            reapExpiredLocked(now: now)
            guard var patch = patches[transferID] else { return }
            patch.isComplete = true
            patch.expiresAt = now.addingTimeInterval(ttl)
            patches[transferID] = patch
        }

        var activeManifestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            reapExpiredLocked(now: Date())
            return manifests.count
        }

        var activePatchCount: Int {
            lock.lock()
            defer { lock.unlock() }
            reapExpiredLocked(now: Date())
            return patches.count
        }

        var manifestCreationCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return createdManifestCount
        }

        var patchCreationCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return createdPatchCount
        }

        func reapExpired(now: Date) {
            lock.lock()
            defer { lock.unlock() }
            reapExpiredLocked(now: now)
        }

        private func removeAll() {
            lock.lock()
            let removedPatches = patches.values
            manifests.removeAll()
            patches.removeAll()
            lock.unlock()
            for patch in removedPatches { removeTransferFile(patch.outputURL) }
        }

        private func reapExpiredLocked(now: Date) {
            for manifestID in manifests.filter({ $0.value.expiresAt <= now }).keys { removeManifestLocked(manifestID) }
            for transferID in patches.filter({ $0.value.expiresAt <= now }).keys { _ = removePatchLocked(transferID) }
        }

        private func removeManifestLocked(_ manifestID: String) {
            manifests.removeValue(forKey: manifestID)
            for transferID in patches.filter({ $0.value.manifestID == manifestID }).keys { _ = removePatchLocked(transferID) }
        }

        @discardableResult private func removePatchLocked(_ transferID: String) -> Bool {
            guard let patch = patches.removeValue(forKey: transferID) else { return false }
            removeTransferFile(patch.outputURL)
            return true
        }

        private func removeTransferFile(_ outputURL: URL) {
            // Each output path is inside its own 0700 UUID directory; deleting that directory releases the
            // private patch and its parent on EOF, explicit cancellation, manifest release, TTL, or shutdown.
            try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
        }
    }
    /// Pure decision for whether the diff-signature poll timer's `tick`th invocation (1-indexed, one per
    /// 2s fire) should broadcast a frame: whenever the computed signature changed, or unconditionally every
    /// 10th tick (~20s) as a keepalive. The keepalive is disconnect detection, not a convenience: the Linux
    /// relay loop (`relayLinuxSubscription`) blocks on a plain `read()` of this scope's producer socket, and
    /// a TLS client disconnecting does not wake that read — only a subsequent write failing does. Forcing a
    /// frame at least every ~20s guarantees `writeTLSResponse` runs often enough to notice a dead peer and
    /// unwind the loop, which is what actually releases the subscriber slot, poll timer, and relay thread
    /// (see `WorkspaceDiffSignatureSubscription`). Extracted as a free function, free of that class's
    /// mutable state, so the cadence is testable without a TLS harness.
    static func workspaceDiffSignatureKeepaliveShouldBroadcast(tick: Int, changed: Bool) -> Bool { changed || tick % 10 == 0 }

    /// Substituted for `signatureProvider`'s result whenever it returns `nil` (most commonly: the workspace
    /// was deleted while a pane stayed subscribed to it), so the poll timer's cadence logic always has a
    /// signature to compare rather than treating "the provider failed" as "stop broadcasting altogether."
    /// Without this, a provider failure would silently stop even the keepalive, reintroducing the Linux
    /// relay leak the keepalive exists to prevent: a relay blocked reading a producer that has gone
    /// permanently silent never gets the write that would surface its dead TLS peer. This sentinel can never
    /// collide with a real signature, which is always a sha256 hex digest; its one broadcast on the
    /// transition into "unavailable" is also the correct signal for a live client, whose re-pull of
    /// `workspaceDiffManifestChunk` then surfaces the workspace's actual 404.
    static let workspaceDiffSignatureUnavailableSentinel = "unavailable"

    /// Same rationale as `workspaceDiffSignatureUnavailableSentinel`, but for the workspace-wide
    /// file-membership stream. `workspaceFileList`-derived signatures are also sha256 hex digests,
    /// so this non-hex sentinel cannot collide with a real signature and keeps the keepalive cadence
    /// alive through provider failures instead of silently freezing the producer.
    static let workspaceFileListSignatureUnavailableSentinel = "unavailable"

    /// Producer + 2s poll timer for one (workspace, ref) scope's `subscribeWorkspaceDiffSignature` stream.
    /// The producer (a reused `DeviceOverviewStreamServer`) and the poll timer both run on `streamQueue`,
    /// never on the shared serial state `queue`, so a slow `git status` during polling can never stall
    /// request dispatch. `streamQueue` is a dedicated serial queue created per scope (see
    /// `addWorkspaceDiffSignatureSubscriber`), never shared across scopes: a wedged repository's git calls
    /// (bounded by the 30s per-command timeout, not instant) degrade only that scope's own poll/keepalive/
    /// socket-accept cadence, never another subscribed scope's — mirroring the per-workspace git queue
    /// (`workspaceGitQueue`) used for `workspaceFileRead`/`Write`/`Diff` requests. `subscriberCount` is the
    /// one exception: it is read/written only from
    /// `addWorkspaceDiffSignatureSubscriber`/`removeWorkspaceDiffSignatureSubscriber`, both confined to
    /// `queue`.
    ///
    /// Signature polling, not filesystem watching: `FileSystemWatcher`'s inotify backend is non-recursive,
    /// so a recursive worktree watch on Linux would mean enumerating every directory within a real
    /// watch-descriptor budget. A subscription-gated 2s poll is one code path on both platforms, computes
    /// nothing while no pane is subscribed, and needs no directory enumeration.
    ///
    /// `signatureProvider` returning nil (the subscribed workspace was deleted) never stops this producer:
    /// the timer handler substitutes `workspaceDiffSignatureUnavailableSentinel` and runs the same
    /// cadence/broadcast logic against it, so the transition into unavailability still broadcasts once and
    /// the keepalive still fires every ~20s afterward, exactly as if the workspace still existed and its
    /// signature had simply changed. `lineProvider` reads that same already-substituted value back out of
    /// `latestSignatureBox` rather than substituting independently (see that box's doc comment); the one
    /// exception is the connect-before-first-tick frame, which has no tick's value to read yet and computes
    /// its own substitution fresh.
    final class WorkspaceDiffSignatureSubscription: @unchecked Sendable {
        /// Shares one poll tick's computed signature between the timer handler (which computes and records
        /// it) and `lineProvider` (which builds the broadcast frame from it), so a broadcast for a tick
        /// never carries a signature more recently recomputed against a filesystem that moved between the
        /// two — the compared value and the broadcast value are the exact same read. A plain class rather
        /// than a tuple/closure-captured var so `lineProvider` (owned by `server`, in turn owned by `self`)
        /// can hold a reference to it directly instead of through `self`: capturing `self` here would create
        /// `self` → `server` → `lineProvider` → `self`, a retain cycle this box exists to avoid.
        ///
        /// Confined to `streamQueue`: the timer handler's write, `lineProvider`'s broadcast-time read, and
        /// `lineProvider`'s connect-time read all run there (see the type doc above), so a plain var needs
        /// no lock.
        private final class LatestSignatureBox: @unchecked Sendable { var signature: String? }

        let socketPath: String
        let server: DeviceOverviewStreamServer
        private let pollTimer: DispatchSourceTimer
        private let latestSignatureBox = LatestSignatureBox()
        /// Last signature broadcast by the poll timer. Compared only from the timer's own handler (always
        /// on `streamQueue`), so it needs no lock. Starts nil, so the first tick after a scope's producer
        /// starts always "changes" and broadcasts once even if nothing moved; a harmless redundant
        /// broadcast the client resolves by re-pulling the same diff.
        private var lastBroadcastSignature: String?
        /// Ticks since this producer started, incremented on every poll timer fire regardless of whether it
        /// broadcasts; feeds `workspaceDiffSignatureKeepaliveShouldBroadcast`. Read/written only from the
        /// timer's own handler.
        private var tick = 0
        /// `queue`-confined; see the type doc above.
        var subscriberCount = 0

        init(
            scope: WorkspaceDiffScope, socketPath: String, streamQueue: DispatchQueue,
            signatureProvider: @escaping @Sendable (WorkspaceDiffScope) -> String?
        ) {
            self.socketPath = socketPath
            let latestSignatureBox = latestSignatureBox
            server = DeviceOverviewStreamServer(
                socketPath: socketPath, queue: streamQueue,
                lineProvider: {
                    // Ordinarily just reads the value the timer handler already computed and recorded this
                    // tick (never recomputes independently — see `LatestSignatureBox`'s doc comment). The one
                    // exception is a client connecting before the first tick fires (+2s after start): the box
                    // is still nil then, so this computes fresh for that one initial frame only, and does NOT
                    // write the result into the box or `lastBroadcastSignature` — the first tick's own
                    // nil-compare still broadcasts a corrective frame regardless, which is the existing
                    // intended behavior `lastBroadcastSignature`'s doc comment describes.
                    let signature =
                        latestSignatureBox.signature ?? signatureProvider(scope) ?? SpacesDeviceAPIServer.workspaceDiffSignatureUnavailableSentinel
                    return try? SpacesDeviceWorkspaceDiffSignatureStreamCodec.encodeLine(
                        SpacesDeviceWorkspaceDiffSignatureFrame(
                            workspaceID: scope.workspaceID, refName: scope.refName, lastCommit: scope.lastCommit, scopeSignature: signature))
                })
            let timer = DispatchSource.makeTimerSource(queue: streamQueue)
            timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
            pollTimer = timer
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.tick += 1
                // Substitute the sentinel rather than returning early on a nil provider result: a permanent
                // provider failure (workspace deleted) must still participate in the keepalive cadence below,
                // or a blocked Linux relay's dead TLS peer is never surfaced. See the sentinel's doc comment.
                let signature = signatureProvider(scope) ?? SpacesDeviceAPIServer.workspaceDiffSignatureUnavailableSentinel
                // Recorded before the broadcast decision below, and unconditionally on every tick (not only
                // on a broadcasting one), so a client connecting between ticks always reads the most recent
                // computation instead of a stale one — see `LatestSignatureBox`'s doc comment for why this
                // is a plain, unrouted-through-`self` reference rather than reaching through `self.server`.
                latestSignatureBox.signature = signature
                let changed = signature != self.lastBroadcastSignature
                guard SpacesDeviceAPIServer.workspaceDiffSignatureKeepaliveShouldBroadcast(tick: self.tick, changed: changed) else { return }
                self.lastBroadcastSignature = signature
                self.server.broadcast()
            }
        }

        func start() throws {
            do { try server.start() } catch {
                // A dispatch source must never be released while suspended (`pollTimer` is created
                // suspended above and only resumed on success) — releasing one traps in libdispatch. Arm
                // then immediately cancel it so this subscription can be discarded safely after an ordinary
                // setup error (e.g. the socket path could not be unlinked/bound).
                pollTimer.resume()
                pollTimer.cancel()
                throw error
            }
            pollTimer.resume()
        }

        func stop() {
            pollTimer.cancel()
            server.stop()
        }
    }

    /// Registers one subscriber for `scope`'s diff-signature stream, creating its producer + 2s poll timer
    /// on the first subscriber and returning its socket path either way. Must run on `queue`.
    private func addWorkspaceDiffSignatureSubscriber(scope: WorkspaceDiffScope) throws -> String {
        if let existing = workspaceDiffSignatureSubscriptions[scope] {
            existing.subscriberCount += 1
            return existing.socketPath
        }
        let socketPath = try TerminalServicePaths.workspaceDiffSignatureSocketPath(
            workspaceID: scope.workspaceID, refName: scope.refName, lastCommit: scope.lastCommit)
        // Dedicated per-scope queue, never shared with any other scope's subscription: a wedged repository's
        // git calls (now up to 30s, per the git-command timeout) must degrade only this scope's poll,
        // keepalive, and producer-socket accept, never another scope's. See the type doc on
        // `WorkspaceDiffSignatureSubscription`.
        let streamQueue = DispatchQueue(
            label: "spaces.workspace-diff-signature.\(scope.workspaceID).\(scope.lastCommit ? "last-commit" : (scope.refName ?? "uncommitted"))")
        let subscription = WorkspaceDiffSignatureSubscription(
            scope: scope, socketPath: socketPath, streamQueue: streamQueue,
            signatureProvider: { [weak self] scope in try? self?.computeWorkspaceDiffScopeSignature(scope: scope) })
        try subscription.start()
        subscription.subscriberCount = 1
        workspaceDiffSignatureSubscriptions[scope] = subscription
        return socketPath
    }

    /// Releases one subscriber for `scope`, tearing its producer + poll timer down once the count reaches
    /// zero. There is no explicit unsubscribe command by design; a relay's connection closing is the only
    /// unsubscribe. Must run on `queue`.
    private func removeWorkspaceDiffSignatureSubscriber(scope: WorkspaceDiffScope) {
        guard let subscription = workspaceDiffSignatureSubscriptions[scope] else { return }
        subscription.subscriberCount -= 1
        guard subscription.subscriberCount <= 0 else { return }
        subscription.stop()
        workspaceDiffSignatureSubscriptions.removeValue(forKey: scope)
    }

    /// Resolves `scope`'s workspace to its checkout directory and computes its `scopeSignature`
    /// (`SpacesDeviceWorkspaceDiffEngine.scopeSignature`), folding in `scope.refName`'s merge-base when
    /// present. Used both by `handleWorkspaceDiffManifestRequest` and by the diff-signature poll timer's
    /// `signatureProvider`, which calls this on that scope's own dedicated `streamQueue` (see
    /// `addWorkspaceDiffSignatureSubscriber`) — a queue with no `RequestContext` of its own — so this opens
    /// its own `SQLiteStore` rather than sharing one, per the confinement rule: a store belongs to the queue
    /// that opened it.
    private func computeWorkspaceDiffScopeSignature(scope: WorkspaceDiffScope) throws -> String {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        guard let workspace = try store.workspace(id: scope.workspaceID) else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Workspace '\(scope.workspaceID)' was not found."])
        }
        return try SpacesDeviceWorkspaceDiffEngine.scopeSignature(
            workspaceDir: workspace.dir, refName: scope.refName, lastCommit: scope.lastCommit, gitClient: workspaceGitClient)
    }

    /// Refuses `scope` before either subscribe transport (macOS `NWConnection` relay, Linux TLS relay)
    /// registers a diff-signature subscription for it, when its workspace directory is not a git
    /// repository. Without this, subscribing against a non-git workspace would sit in
    /// `WorkspaceDiffSignatureSubscription`'s poll loop silently producing nothing (`signatureProvider`
    /// swallows its own errors via `try?`), leaving the client to read "unavailable" with no renderable
    /// reason instead of the same typed refusal `handleWorkspaceDiffManifestRequest` gives for the same case. Opens
    /// its own `SQLiteStore`, matching `computeWorkspaceDiffScopeSignature`'s confinement rule, since callers
    /// run on `queue` before any per-scope `streamQueue` (and thus any `RequestContext`) exists yet.
    ///
    /// This runs synchronously on `queue` — the server's single serial state queue, shared by pings and
    /// every other client's requests — rather than hopping to the per-workspace git queue the way
    /// `handleWorkspaceDiffManifestRequest` and the diff-signature poll loop do for their own git work. That is a
    /// deliberate, bounded exception: `isRepo`'s `rev-parse --is-inside-work-tree` probe runs on
    /// `metadataCommandTimeout` (2s), and if that expires against a stalled workspace filesystem,
    /// `runGitAndCapture` still bounds its post-timeout pipe drain to `drainGrace` (2s) rather than blocking
    /// on a lingering descendant — so the worst-case hold on `queue` is ~4s, only while the workspace's
    /// filesystem is actually hung at subscribe time. A healthy local worktree answers in milliseconds, and
    /// the stall self-heals the moment the timeout fires; it does not compound across subscribe calls.
    /// Fixing this properly would mean async-ifying subscription registration on both transports (the
    /// macOS `NWConnection` relay and the Linux `handleClient` return shape) so it can hop to the
    /// per-workspace queue and back before registering — a shape change to both transports to shave a
    /// bounded, self-healing ~4s edge case, which is disproportionate to the risk. For the same reason,
    /// this deliberately does NOT also probe `scope.refName`'s resolvability (see
    /// `SpacesDeviceWorkspaceDiffEngine.assertRefIsResolvable`) — that would add a second synchronous git
    /// subprocess call to this same bounded blocking window; an unresolvable ref instead surfaces
    /// correctly once `handleWorkspaceDiffManifestRequest`'s own check runs, when the pane's manifest pull
    /// fires from the resulting signature event, and this subscribe path already treats failures here as
    /// best-effort/retry.
    /// Rejects the same `lastCommit`+`refName` combination `handleWorkspaceDiffManifestRequest` rejects on the pull
    /// path (see that function's up-front check), before either subscribe transport registers a
    /// diff-signature subscription for it. Without this, a subscription for the combination would sit
    /// alongside a pull path that always 400s for the identical scope: the client could never successfully
    /// fetch a diff for what it just subscribed to.
    ///
    /// Takes the raw payload fields, not a `WorkspaceDiffScope`, because `WorkspaceDiffScope.init`
    /// normalizes `refName` (blank/whitespace collapses to `nil`) but does not reject the combination —
    /// constructing the scope first and inspecting it here would silently accept a blank-`refName` request
    /// that paired `lastCommit: true` with a non-blank ref, since normalization already erased the
    /// distinction this check needs.
    private func assertWorkspaceDiffSignatureScopeIsUnambiguous(refName: String?, lastCommit: Bool) throws {
        if lastCommit, SpacesDeviceWorkspaceDiffEngine.normalizedRefName(refName) != nil {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "lastCommit and refName are mutually exclusive."])
        }
    }

    private func assertWorkspaceDiffScopeIsGitRepository(scope: WorkspaceDiffScope) throws {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        guard let workspace = try store.workspace(id: scope.workspaceID) else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Workspace '\(scope.workspaceID)' was not found."])
        }
        try SpacesDeviceWorkspaceDiffEngine.assertIsGitRepository(workspaceDir: workspace.dir, gitClient: workspaceGitClient)
    }

    /// Identifies one `subscribeWorkspaceFileSignature` subscription's target: a single workspace-relative
    /// path within one workspace. Unlike `WorkspaceDiffScope`, there is no ref-name normalization concern —
    /// the path is used exactly as the client supplied it (two different strings that happen to name the
    /// same file, e.g. via a redundant `./` segment, are treated as different scopes; not expected to matter
    /// in practice since the web app always subscribes with the exact path it just read).
    struct WorkspaceFileScope: Hashable, Sendable {
        let workspaceID: String
        let path: String
    }

    /// One poll tick's computed file-signature value. A plain struct rather than a bare
    /// `(sha256: String?, missing: Bool)` tuple since Swift tuples aren't `Equatable`, and this is compared
    /// tick-to-tick to decide whether to broadcast.
    struct WorkspaceFileSignatureValue: Equatable {
        let sha256: String?
        let missing: Bool
    }

    /// Substituted for the real content hash in `computeWorkspaceFileScopeSignature` whenever the watched
    /// file is a regular, existing file over `workspaceFileMaxBytes` (10 MiB) — the same cap
    /// `handleWorkspaceFileReadRequest` enforces on a bounded read. Unlike that request handler, the
    /// 2-second poll timer that computes this value runs for the pane's entire subscription lifetime, and
    /// the client deliberately keeps a subscription alive on a file whose *open* was already rejected as
    /// oversized (see the recovery-subscription comment in
    /// `CodePaneContentController.restoreFileSignatureMonitoringAfterFailedOpen`), specifically to learn
    /// when it shrinks back under the cap. Without a gate here, that subscription would fully re-read and
    /// hash a multi-GB file every 2 seconds for as long as the pane stays open.
    ///
    /// A stable sentinel, not a skipped tick, because this state needs to be broadcast and deduped like any
    /// other signature: skipping would mean an oversized file gets no connect-time frame, and a
    /// readable→oversized transition would go silent instead of announcing itself the way every other
    /// signature change does. This value is stable for as long as the file stays over the cap (it does not
    /// vary with the file's exact size), so `lastBroadcastValue`'s tick-to-tick comparison suppresses every
    /// repeat tick and an actively growing file broadcasts nothing after the first crossing. It can never
    /// collide with a real signature (never 64 hex characters) or with the missing state (`sha256: nil`),
    /// so crossing the cap in either direction always compares as changed and broadcasts exactly once.
    static let workspaceFileSignatureOversizedSentinel = "oversized"

    /// Producer + 2s poll timer for one (workspace, path) scope's `subscribeWorkspaceFileSignature` stream.
    /// Mirrors `WorkspaceDiffSignatureSubscription`'s architecture (producer + poll timer on a dedicated
    /// `streamQueue`, connect-time frame from the latest computed value, keepalive cadence via
    /// `workspaceDiffSignatureKeepaliveShouldBroadcast`, reused unchanged — see that function's doc comment)
    /// with one deliberate divergence: a provider FAILURE here (the file is unreadable or unresolvable — see
    /// `computeWorkspaceFileScopeSignature`'s `nil` returns) SKIPS the tick's broadcast/`lastBroadcastValue`
    /// update entirely, rather than substituting a sentinel the way diff's `workspaceDiffSignatureUnavailableSentinel`
    /// does: failure has no meaningful wire value to report, so inventing one would be arbitrary. An
    /// OVERSIZED file is a different case and is not treated as a failure: it is an authoritative,
    /// reportable file state with its own dedicated sentinel (`workspaceFileSignatureOversizedSentinel`),
    /// broadcast and deduped the same way `missing` is — see that constant's doc comment and
    /// `computeWorkspaceFileScopeSignature`'s size gate. `tick` still increments unconditionally on every fire (including a skipped one) so the
    /// ~20s keepalive cadence measured in tick count keeps counting through an intermittent failure.
    /// Accepted gap: a Linux relay's keepalive-based disconnect detection pauses for the duration of a
    /// persistent read failure (e.g. a permissions error mid-poll) and resumes the moment the file becomes
    /// readable again — narrower than diff's guarantee, but this keeps the contract simple and singular
    /// rather than adding a sentinel value with no natural meaning here.
    final class WorkspaceFileSignatureSubscription: @unchecked Sendable {
        /// Mirrors `WorkspaceDiffSignatureSubscription.LatestSignatureBox`'s role and retain-cycle rationale
        /// exactly, just holding a `WorkspaceFileSignatureValue` instead of a signature string.
        private final class LatestValueBox: @unchecked Sendable { var value: WorkspaceFileSignatureValue? }

        let socketPath: String
        let server: DeviceOverviewStreamServer
        private let pollTimer: DispatchSourceTimer
        private let latestValueBox = LatestValueBox()
        /// Last value broadcast by the poll timer; starts nil so the first tick always "changes" and
        /// broadcasts once. Compared only from the timer's own handler (always on `streamQueue`).
        private var lastBroadcastValue: WorkspaceFileSignatureValue?
        /// Ticks since this producer started, incremented on every poll timer fire regardless of whether it
        /// broadcasts OR is skipped for a provider failure; feeds `workspaceDiffSignatureKeepaliveShouldBroadcast`.
        private var tick = 0
        /// `queue`-confined; see the type doc above.
        var subscriberCount = 0

        init(
            scope: WorkspaceFileScope, socketPath: String, streamQueue: DispatchQueue,
            signatureProvider: @escaping @Sendable (WorkspaceFileScope) -> WorkspaceFileSignatureValue?
        ) {
            self.socketPath = socketPath
            let latestValueBox = latestValueBox
            server = DeviceOverviewStreamServer(
                socketPath: socketPath, queue: streamQueue,
                lineProvider: {
                    // Ordinarily just reads the value the timer handler already computed and recorded this
                    // tick. The one exception is a client connecting before the first tick fires (+2s after
                    // start): the box is still nil then, so this computes fresh for that one initial frame
                    // only, and does NOT write the result into the box or `lastBroadcastValue`. If even that
                    // fresh computation fails (provider returns nil), there is nothing to report for the
                    // connect-time frame — matching the tick handler's own skip-on-failure behavior.
                    guard let value = latestValueBox.value ?? signatureProvider(scope) else { return nil }
                    return try? SpacesDeviceWorkspaceFileSignatureStreamCodec.encodeLine(
                        SpacesDeviceWorkspaceFileSignatureFrame(
                            workspaceID: scope.workspaceID, path: scope.path, sha256: value.sha256, missing: value.missing))
                })
            let timer = DispatchSource.makeTimerSource(queue: streamQueue)
            timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
            pollTimer = timer
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.tick += 1
                // Divergence from diff's sentinel-substitution: skip this tick's broadcast/lastBroadcastValue
                // update entirely on a provider failure, rather than substituting a stand-in value. See the
                // type doc above for why. `tick` above was already incremented unconditionally, so the
                // keepalive cadence keeps counting through the failure.
                guard let value = signatureProvider(scope) else { return }
                latestValueBox.value = value
                let changed = value != self.lastBroadcastValue
                guard SpacesDeviceAPIServer.workspaceDiffSignatureKeepaliveShouldBroadcast(tick: self.tick, changed: changed) else { return }
                self.lastBroadcastValue = value
                self.server.broadcast()
            }
        }

        func start() throws {
            do { try server.start() } catch {
                // See `WorkspaceDiffSignatureSubscription.start()`'s identical comment: a dispatch source
                // must never be released while suspended, so arm then immediately cancel on setup failure.
                pollTimer.resume()
                pollTimer.cancel()
                throw error
            }
            pollTimer.resume()
        }

        func stop() {
            pollTimer.cancel()
            server.stop()
        }
    }

    /// Registers one subscriber for `scope`'s file-signature stream, creating its producer + 2s poll timer
    /// on the first subscriber and returning its socket path either way. Must run on `queue`.
    private func addWorkspaceFileSignatureSubscriber(scope: WorkspaceFileScope) throws -> String {
        if let existing = workspaceFileSignatureSubscriptions[scope] {
            existing.subscriberCount += 1
            return existing.socketPath
        }
        let socketPath = try TerminalServicePaths.workspaceFileSignatureSocketPath(workspaceID: scope.workspaceID, path: scope.path)
        // Dedicated per-scope queue, never shared with any other scope's subscription — mirrors
        // `addWorkspaceDiffSignatureSubscriber`'s own per-scope queue rationale.
        let streamQueue = DispatchQueue(label: "spaces.workspace-file-signature.\(scope.workspaceID).\(scope.path)")
        let subscription = WorkspaceFileSignatureSubscription(
            scope: scope, socketPath: socketPath, streamQueue: streamQueue,
            signatureProvider: { [weak self] scope in self?.computeWorkspaceFileScopeSignature(scope: scope) })
        try subscription.start()
        subscription.subscriberCount = 1
        workspaceFileSignatureSubscriptions[scope] = subscription
        return socketPath
    }

    /// Releases one subscriber for `scope`, tearing its producer + poll timer down once the count reaches
    /// zero. There is no explicit unsubscribe command by design; a relay's connection closing is the only
    /// unsubscribe. Must run on `queue`.
    private func removeWorkspaceFileSignatureSubscriber(scope: WorkspaceFileScope) {
        guard let subscription = workspaceFileSignatureSubscriptions[scope] else { return }
        subscription.subscriberCount -= 1
        guard subscription.subscriberCount <= 0 else { return }
        subscription.stop()
        workspaceFileSignatureSubscriptions.removeValue(forKey: scope)
    }

    /// Resolves `scope`'s workspace + path and computes its content-signature. Used by the file-signature
    /// poll timer's `signatureProvider`, which calls this on that scope's own dedicated `streamQueue` (see
    /// `addWorkspaceFileSignatureSubscriber`) — a queue with no `RequestContext` of its own — so this opens
    /// its own `SQLiteStore` rather than sharing one, matching `computeWorkspaceDiffScopeSignature`'s
    /// confinement rule. Returns nil on any resolution/read failure (the provider-failure/skip-tick signal),
    /// mirroring `computeWorkspaceDiffScopeSignature`'s own `try?`-swallowed-by-caller shape.
    private func computeWorkspaceFileScopeSignature(scope: WorkspaceFileScope) -> WorkspaceFileSignatureValue? {
        guard let store = try? SQLiteStore(path: DatabaseLocator.defaultPath()), let workspace = try? store.workspace(id: scope.workspaceID) else {
            return nil
        }
        guard let resolvedPath = try? SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: scope.path, workspaceDir: workspace.dir)
        else { return nil }
        // A stat, not a plain `fileExists` check: `attributesOfItem` never blocks, even against a FIFO
        // or socket, but the hashing open below does — see `handleWorkspaceFileReadRequest`'s identical
        // guard for the full FIFO-wedge rationale ("this guard is the fix, not a timeout around the
        // read"). A watched regular file that gets replaced on disk by a FIFO (or a symlink resolving to
        // one) still passes a bare `fileExists`, and the subsequent hashing open then blocks
        // indefinitely — wedging this scope's dedicated `streamQueue` forever, killing both further
        // signature frames and the keepalive cadence.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath) else {
            return WorkspaceFileSignatureValue(sha256: nil, missing: true)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            // The scope was validated at subscribe time (`assertWorkspaceFileScopeIsValid`) against a
            // then-regular file; a non-regular replacement afterward (the FIFO-swap case above) is a
            // transient/abnormal on-disk state, not a missing file — treated the same as an existing but
            // unreadable file: skip this tick's broadcast entirely rather than reporting a signature for
            // content that was never actually hashed. `tick` still increments in the caller regardless
            // (see `WorkspaceFileSignatureSubscription`'s doc comment), so the keepalive cadence keeps
            // counting through this skip and the connection doesn't look dead.
            //
            // This is a stat-then-open TOCTOU pair, same as `handleWorkspaceFileReadRequest`'s own
            // accepted, documented risk: the file could still be swapped for something non-regular in the
            // gap between this stat and the hashing open below. Not worth a second stat (it wouldn't close
            // the gap) or a timeout on the open (this guard is what makes the common, long-lived
            // replacement case safe; the race is orthogonal and already accepted elsewhere in this file).
            return nil
        }
        // Stat-based size gate: this poll runs every 2s for the whole life of a subscription, unlike
        // `handleWorkspaceFileReadRequest`'s one-shot bounded read, so hashing here has no natural size
        // bound of its own — see `workspaceFileSignatureOversizedSentinel`'s doc comment for why an
        // oversized file gets a stable sentinel instead of either an unbounded hash or a skipped tick.
        guard let size = attributes[.size] as? Int else { return nil }
        if size > Self.workspaceFileMaxBytes {
            return WorkspaceFileSignatureValue(sha256: Self.workspaceFileSignatureOversizedSentinel, missing: false)
        }
        // Stat-then-hash TOCTOU: a file that grows past the cap between this stat and the hashing open
        // below gets one full hash of whatever is on disk at open time; the next tick's stat catches the
        // crossing. Same accepted stat-then-open race as `handleWorkspaceFileReadRequest`'s documented
        // pair — the cost here is one-time, replacing what was previously a continuous per-tick cost.
        guard let hash = SpacesDeviceWorkspaceGitHashing.streamingSHA256Hex(atPath: resolvedPath) else { return nil }
        return WorkspaceFileSignatureValue(sha256: hash, missing: false)
    }

    /// Validates a file-signature scope's workspace + path the same way `handleWorkspaceFileReadRequest`
    /// validates a `workspaceFileRead` request (workspace-root confinement, symlink rules), so a bad path
    /// is rejected synchronously at subscribe time with a typed error instead of the poll loop silently
    /// producing nothing forever. Opens its own `SQLiteStore` since this runs at relay/subscribe time, off
    /// any `RequestContext` — same reason `computeWorkspaceDiffScopeSignature` opens its own store.
    ///
    /// Unlike diff's `assertWorkspaceDiffScopeIsGitRepository` (which validates a git-repository
    /// requirement that has no equivalent here — a plain file read/signature is git-independent, exactly
    /// like `workspaceFileRead`/`workspaceFileWrite`), this validates only that the scope resolves to a
    /// real, contained path; it does not require the path to currently exist (a missing file is a valid,
    /// reportable state — see `WorkspaceFileSignatureFrame.missing` — not a subscribe-time refusal).
    private func assertWorkspaceFileScopeIsValid(scope: WorkspaceFileScope) throws {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        guard let workspace = try store.workspace(id: scope.workspaceID) else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Workspace '\(scope.workspaceID)' was not found."])
        }
        do { _ = try SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: scope.path, workspaceDir: workspace.dir) } catch {
            // Rethrown as the same typed, `errorCode(for:)`-mapped shape `handleWorkspaceFileReadRequest`
            // uses for this identical failure, rather than letting the raw `PathError.escapesWorkspace`
            // propagate — that generic error has no domain/code mapping and would fall through to
            // `.internalError`, misreporting a client mistake (an escaping path) as a server fault.
            throw NSError(domain: "SpacesDeviceAPIServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Path escapes the workspace directory."])
        }
    }

    /// Producer + 2s poll timer for one workspace's `subscribeWorkspaceFileListSignature` stream.
    /// The wire frame remains the exact `workspaceFileList` signature, which is the value a successful
    /// pull acknowledges. Polls use a cheaper membership detector and refresh that cached exact value only
    /// when the detector moves; otherwise a keepalive simply repeats the cache without listing the tree.
    final class WorkspaceFileListSignatureSubscription: @unchecked Sendable {
        private final class LatestSignatureBox: @unchecked Sendable {
            var signature: String?
            var detectorToken: String?
            var lastBroadcastSignature: String?
        }

        let socketPath: String
        let server: DeviceOverviewStreamServer
        private let pollTimer: DispatchSourceTimer
        private let latestSignatureBox = LatestSignatureBox()
        private var tick = 0
        var subscriberCount = 0

        init(
            workspaceID: String, socketPath: String, streamQueue: DispatchQueue, signatureProvider: @escaping @Sendable (String) -> String?,
            detectorProvider: @escaping @Sendable (String) -> String?
        ) {
            self.socketPath = socketPath
            let latestSignatureBox = latestSignatureBox
            let initialize: @Sendable () -> String = {
                if let signature = latestSignatureBox.signature { return signature }
                // Establish the detector baseline before taking the exact listing. The filesystem can
                // change between these two calls (an agent can create/remove a file in that window). If
                // the exact listing ran first, the detector could observe the post-change state and make
                // that stale listing look current forever. A detector-first baseline may cause one extra
                // exact refresh when the change lands during the listing, but it cannot suppress it.
                let detectorToken = detectorProvider(workspaceID)
                let exactSignature = signatureProvider(workspaceID)
                let signature = exactSignature ?? SpacesDeviceAPIServer.workspaceFileListSignatureUnavailableSentinel
                latestSignatureBox.signature = signature
                // A failed exact listing has no trustworthy detector baseline: retaining one would
                // let identical later detector ticks keep the unavailable sentinel cached forever.
                latestSignatureBox.detectorToken = exactSignature == nil ? nil : detectorToken
                // This is the connection's initial frame. Recording it as sent means the first poll does
                // not re-announce the same exact signature and make an already-current client re-pull.
                latestSignatureBox.lastBroadcastSignature = signature
                return signature
            }
            server = DeviceOverviewStreamServer(
                socketPath: socketPath, queue: streamQueue,
                lineProvider: {
                    let signature = initialize()
                    // A timer may have initialized the cache before the first client connected. In
                    // that case this connect-time frame is the first actual broadcast, so acknowledge
                    // it as sent; otherwise the next timer would immediately re-announce the same
                    // signature solely because there was no relay at the earlier tick.
                    if latestSignatureBox.lastBroadcastSignature == nil { latestSignatureBox.lastBroadcastSignature = signature }
                    return try? SpacesDeviceWorkspaceFileListSignatureStreamCodec.encodeLine(
                        SpacesDeviceWorkspaceFileListSignatureFrame(workspaceID: workspaceID, fileListSignature: signature))
                })
            let timer = DispatchSource.makeTimerSource(queue: streamQueue)
            timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
            pollTimer = timer
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.tick += 1
                if latestSignatureBox.signature == nil {
                    // A timer can fire before any relay connects. It must establish the same cache as the
                    // connect path, but has not sent a frame yet, so leave `lastBroadcastSignature` nil.
                    // Keep initialization's detector-first ordering so a change during the exact listing
                    // cannot be hidden by a detector baseline captured afterward.
                    let detectorToken = detectorProvider(workspaceID)
                    let exactSignature = signatureProvider(workspaceID)
                    latestSignatureBox.signature = exactSignature ?? SpacesDeviceAPIServer.workspaceFileListSignatureUnavailableSentinel
                    latestSignatureBox.detectorToken = exactSignature == nil ? nil : detectorToken
                } else {
                    let detectorToken = detectorProvider(workspaceID)
                    if latestSignatureBox.detectorToken == nil || detectorToken != latestSignatureBox.detectorToken {
                        let exactSignature = signatureProvider(workspaceID)
                        latestSignatureBox.signature = exactSignature ?? SpacesDeviceAPIServer.workspaceFileListSignatureUnavailableSentinel
                        // Same invariant as the connect path: retry a failed exact pull on the
                        // following detector tick even if membership itself stayed unchanged.
                        latestSignatureBox.detectorToken = exactSignature == nil ? nil : detectorToken
                    }
                }
                let signature = latestSignatureBox.signature ?? SpacesDeviceAPIServer.workspaceFileListSignatureUnavailableSentinel
                let changed = signature != latestSignatureBox.lastBroadcastSignature
                guard SpacesDeviceAPIServer.workspaceDiffSignatureKeepaliveShouldBroadcast(tick: self.tick, changed: changed) else { return }
                latestSignatureBox.lastBroadcastSignature = signature
                self.server.broadcast()
            }
        }

        func start() throws {
            do { try server.start() } catch {
                pollTimer.resume()
                pollTimer.cancel()
                throw error
            }
            pollTimer.resume()
        }

        func stop() {
            pollTimer.cancel()
            server.stop()
        }
    }

    private func addWorkspaceFileListSignatureSubscriber(workspaceID: String) throws -> String {
        if let existing = workspaceFileListSignatureSubscriptions[workspaceID] {
            existing.subscriberCount += 1
            return existing.socketPath
        }
        let socketPath = try TerminalServicePaths.workspaceFileListSignatureSocketPath(workspaceID: workspaceID)
        let streamQueue = DispatchQueue(label: "spaces.workspace-file-list-signature.\(workspaceID)")
        let indexCache = SpacesDeviceWorkspaceFileListEngine.GitMembershipIndexCache()
        let subscription = WorkspaceFileListSignatureSubscription(
            workspaceID: workspaceID, socketPath: socketPath, streamQueue: streamQueue,
            signatureProvider: { [weak self] workspaceID in try? self?.computeWorkspaceFileListSignature(workspaceID: workspaceID) },
            detectorProvider: { [weak self] workspaceID in
                try? self?.computeWorkspaceFileListChangeDetector(workspaceID: workspaceID, indexCache: indexCache)
            })
        try subscription.start()
        subscription.subscriberCount = 1
        workspaceFileListSignatureSubscriptions[workspaceID] = subscription
        return socketPath
    }

    private func removeWorkspaceFileListSignatureSubscriber(workspaceID: String) {
        guard let subscription = workspaceFileListSignatureSubscriptions[workspaceID] else { return }
        subscription.subscriberCount -= 1
        guard subscription.subscriberCount <= 0 else { return }
        subscription.stop()
        workspaceFileListSignatureSubscriptions.removeValue(forKey: workspaceID)
    }

    private func computeWorkspaceFileListSignature(workspaceID: String) throws -> String {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        guard let workspace = try store.workspace(id: workspaceID) else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Workspace '\(workspaceID)' was not found."])
        }
        let result = try SpacesDeviceWorkspaceFileListEngine.listFiles(workspaceDir: workspace.dir, gitClient: workspaceGitClient)
        return SpacesDeviceWorkspaceFileListSignature.value(for: result)
    }

    /// Produces the poll-only file-membership detector. Git has an index/status source that can distinguish
    /// membership from ordinary content edits; a plain directory has no equivalent recursive change journal,
    /// and a parent-directory mtime misses nested changes and 10 MiB/symlink openability crossings. Its
    /// exact listing signature is therefore the smallest correct detector rather than a lossy shortcut.
    private func computeWorkspaceFileListChangeDetector(
        workspaceID: String, indexCache: SpacesDeviceWorkspaceFileListEngine.GitMembershipIndexCache? = nil
    ) throws -> String {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        guard let workspace = try store.workspace(id: workspaceID) else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Workspace '\(workspaceID)' was not found."])
        }
        if let context = try SpacesDeviceWorkspaceFileListEngine.gitMembershipContext(
            workspaceDir: workspace.dir, gitClient: workspaceGitClient, indexCache: indexCache)
        {
            return "git:\(try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: workspaceGitClient))"
        }
        let result = try SpacesDeviceWorkspaceFileListEngine.listFiles(workspaceDir: workspace.dir, gitClient: workspaceGitClient)
        return "filesystem:\(SpacesDeviceWorkspaceFileListSignature.value(for: result))"
    }

    private func assertWorkspaceExistsForFileListSignature(workspaceID: String) throws {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        guard try store.workspace(id: workspaceID) != nil else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Workspace '\(workspaceID)' was not found."])
        }
    }

    /// Stops accepting and tears the transport down on the Device API queue. Uses `performOnQueue` rather
    /// than a bare `async` so a stop requested from that queue takes effect at that point instead of
    /// behind everything already queued ahead of it — the same inline-if-already-there rule the rest of
    /// this class's queue entry points follow.
    public func stop() { performOnQueue { self.stopOnQueue() } }

    func revokePairing(installationID: String) throws -> [SpacesDevicePairedClient] {
        try syncOnQueue {
            try self.pairingStore.revoke(installationID: installationID)
            self.closeStreamRelaysOnQueue(forInstallationID: installationID)
            return try self.pairingStore.listDevices()
        }
    }

    func resetPairingsAndStop() throws {
        try syncOnQueue {
            self.stopOnQueue()
            try self.pairingStore.removeAll()
        }
    }

    public func closeStreamRelays(forInstallationID installationID: String) {
        let normalizedID = installationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }

        if DispatchQueue.getSpecific(key: queueKey) != nil {
            closeStreamRelaysOnQueue(forInstallationID: normalizedID)
        } else {
            queue.async { self.closeStreamRelaysOnQueue(forInstallationID: normalizedID) }
        }
    }

    public func openPairingWindow(
        hosts linkHosts: [String], name: String, duration: TimeInterval = SpacesDevicePairingCoordinator.defaultWindowDuration
    ) -> SpacesDevicePairingWindow {
        pairingCoordinator.openWindow(
            hosts: linkHosts, port: listeningPort > 0 ? listeningPort : port, certificateFingerprint: identity.certificateFingerprint, name: name,
            protocolVersion: SpacesWireProtocol.version, appVersion: AppVersion.short, duration: duration)
    }

    public func openPairingWindow(
        hosts linkHosts: [String], name: String, duration: TimeInterval = SpacesDevicePairingCoordinator.defaultWindowDuration, code: String,
        nonce: String? = nil
    ) -> SpacesDevicePairingWindow {
        pairingCoordinator.openWindow(
            hosts: linkHosts, port: listeningPort > 0 ? listeningPort : port, certificateFingerprint: identity.certificateFingerprint, name: name,
            protocolVersion: SpacesWireProtocol.version, appVersion: AppVersion.short, duration: duration, code: code, nonce: nonce)
    }

    public func pairingWindowSnapshot() -> SpacesDevicePairingWindowSnapshot? { pairingCoordinator.snapshot() }

    /// Per-request database access shared across a single request's handler,
    /// `refreshedMutationResponse`, and overview build so one request pays a single
    /// `SQLiteStore` open (schema check + integrity check) instead of two or three.
    ///
    /// The store opens lazily on first use so commands that never touch the database
    /// (ping, pairing, terminal control, directory listing, terminal-link chunk reads,
    /// and the conditional non-file `resolveTerminalLink` path) pay no open.
    ///
    /// Confinement: a context is created inside `handleRequest` (serial `spaces.device.api`
    /// queue), `handleWorkspaceTeardownRequest` (serial `workspaceTeardownQueue`),
    /// `handleWorkspaceStopRequest` (serial `workspaceStopQueue`), or `handleWorkspaceSetupRequest`
    /// (serial `workspaceSetupQueue`), and it never escapes that request's stack frame. It must not be
    /// stored on the server or captured into an escaping closure — the off-request paths (overview-stream
    /// `lineProvider`, `loadDaemonStatus`, and the two background launch/setup paths) each open
    /// their own store on their own queue.
    private final class RequestContext {
        private let orchestratorFactory: (SQLiteStore) -> WorkspaceOrchestrator
        private var openedStore: SQLiteStore?
        private var openedOrchestrator: WorkspaceOrchestrator?

        init(orchestratorFactory: @escaping (SQLiteStore) -> WorkspaceOrchestrator) { self.orchestratorFactory = orchestratorFactory }

        func store() throws -> SQLiteStore {
            if let openedStore { return openedStore }
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            openedStore = store
            return store
        }

        func orchestrator() throws -> WorkspaceOrchestrator {
            if let openedOrchestrator { return openedOrchestrator }
            let orchestrator = orchestratorFactory(try store())
            openedOrchestrator = orchestrator
            return orchestrator
        }
    }

    private func handleRequest(_ request: SpacesDeviceAPIRequest, peerID: String) throws -> SpacesDeviceAPIResponse {
        let context = RequestContext { [self] store in deviceOrchestrator(store: store) }
        switch request.command {
        case .pair(let payload):
            guard let clientApp = request.clientApp else {
                return SpacesDeviceAPIResponse(ok: false, message: SpacesDevicePairingError.missingClientApp.localizedDescription)
            }
            // Version-gate before validating the code so an incompatible client never consumes the
            // one-time pairing window. A missing clientProtocolVersion reads as an incompatible (too
            // old) client. This runs pre-authentication, so it discloses the daemon's app version.
            if let incompatibility = Self.pairingVersionRejection(clientProtocolVersion: payload.clientProtocolVersion) {
                return SpacesDeviceAPIResponse(ok: false, message: incompatibility)
            }
            try pairingStore.validate(clientApp: clientApp)
            try pairingCoordinator.validate(code: payload.pairingCode, nonce: payload.pairingNonce, peerID: peerID)
            // A fresh pairing always mints a new token; there is no prior token to preserve.
            let issuedToken = try pairingStore.issueToken(for: clientApp, presentedToken: nil)
            onPairingSucceeded?(clientApp)
            return SpacesDeviceAPIResponse(ok: true, message: "Paired iOS client.", result: .issuedAuthToken(.init(authToken: issuedToken)))
        // Both transports answer `.ping` before it reaches this queue (see `isPingCommand`), so this
        // case only keeps the switch exhaustive.
        case .ping: return Self.pongResponse
        case .daemonStatus: return SpacesDeviceAPIResponse(ok: true, message: "Loaded daemon status.", result: .daemonStatus(try loadDaemonStatus()))
        case .requestDaemonRestart:
            guard let onRestartRequested else {
                return SpacesDeviceAPIResponse(ok: false, message: "This daemon cannot restart itself.", errorCode: .capabilityMissing)
            }
            onRestartRequested()
            return SpacesDeviceAPIResponse(ok: true, message: "spacesd is restarting.")
        case .overview:
            return SpacesDeviceAPIResponse(
                ok: true, message: "Loaded device overview.",
                result: .overview(try loadOverview(store: context.store(), clientApp: request.clientApp)))
        case .createProject(let payload): return try handleCreateProjectRequest(payload, context: context)
        case .previewGitProject(let payload): return try handleGitPreviewRequest(payload, context: context)
        // Both transports divert workspace-teardown commands to `workspaceTeardownQueue` before they reach
        // here (see `runsOnWorkspaceTeardownQueue`), so this case only keeps the switch exhaustive.
        case .deleteProject, .archiveWorkspace: return try handleWorkspaceTeardownRequest(request)
        // Both transports divert `.stopWorkspace` to `workspaceStopQueue` before they reach here (see
        // `runsOnWorkspaceStopQueue`), so this case only keeps the switch exhaustive.
        case .stopWorkspace: return try handleWorkspaceStopRequest(request)
        // Both transports divert `.runWorkspaceSetup` to `workspaceSetupQueue` before they reach here (see
        // `runsOnWorkspaceSetupQueue`), so this case only keeps the switch exhaustive.
        case .runWorkspaceSetup: return try handleWorkspaceSetupRequest(request)
        // Both transports divert workspace file-read/write/diff/file-list/ref-list commands to
        // `workspaceGitQueue` before they reach here (see `runsOnWorkspaceGitQueue`), so this case only
        // keeps the switch exhaustive.
        case .workspaceFileRead, .workspaceRevisionFileRead, .workspaceFileWrite, .workspaceDiffManifestChunk, .workspaceDiffManifestRelease,
            .workspaceDiffFileChunk,
            .workspaceFileList, .workspaceRefList:
            return try handleWorkspaceGitRequest(request)
        case .importProject(let payload): return try handleImportProjectRequest(payload, context: context)
        case .exportProject(let payload): return try handleExportProjectRequest(payload, context: context)
        case .previewProject(let payload): return try handlePreviewProjectRequest(payload, context: context)
        case .listDirectories(let payload): return try handleListDirectoriesRequest(payload)
        case .workspaceCreateOptions(let payload): return try handleWorkspaceCreateOptionsRequest(payload, context: context)
        case .createWorkspace(let payload): return try handleCreateWorkspaceRequest(payload, context: context)
        case .launchWorkspace(let payload): return try handleLaunchWorkspaceRequest(payload, context: context)
        case .restartWorkspace(let payload): return try handleRestartWorkspaceRequest(payload, context: context)
        case .updateProjectConfig(let payload): return try handleUpdateProjectConfigRequest(payload, context: context)
        case .updateProjectMetadata(let payload): return try handleUpdateProjectMetadataRequest(payload, context: context)
        case .updateWorkspaceConfig(let payload): return try handleUpdateWorkspaceConfigRequest(payload, context: context)
        case .updateWorkspaceMetadata(let payload): return try handleUpdateWorkspaceMetadataRequest(payload, context: context)
        // Plain SQLite CRUD against `workspace_review_comments` — no filesystem/git work, so unlike
        // workspaceFileRead/Write/Diff this has no need for the per-workspace `workspaceGitQueue`
        // serialization and runs inline on the main serial device-API queue like every other read: it's
        // read-only and fast, unlike upsert/delete/send below, which all divert to a terminal-control
        // lane instead (see `runsOnTerminalControlLane`).
        case .workspaceReviewCommentList(let payload): return try handleWorkspaceReviewCommentListRequest(payload, context: context)
        case .openWorkspaceTerminal(let payload): return try handleOpenWorkspaceTerminalRequest(payload, context: context)
        case .startWorkspaceCommandSession(let payload): return try handleStartWorkspaceCommandSessionRequest(payload, context: context)
        case .stopWorkspaceTerminal(let payload): return try handleStopWorkspaceTerminalRequest(payload, context: context)
        case .stopWorkspaceTerminalIfBareShell(let payload): return try handleStopWorkspaceTerminalIfBareShellRequest(payload, context: context)
        case .renameTerminalSession(let payload): return try handleRenameTerminalSessionRequest(payload, context: context)
        case .runWorkspaceProcess(let payload): return try handleRunWorkspaceProcessRequest(payload, context: context)
        case .stopWorkspaceProcess(let payload): return try handleStopWorkspaceProcessRequest(payload, context: context)
        case .restartWorkspaceProcess(let payload): return try handleRestartWorkspaceProcessRequest(payload, context: context)
        case .stopCodingAgent(let payload): return try handleStopCodingAgentRequest(payload, context: context)
        case .renameAgentSession(let payload): return try handleRenameAgentSessionRequest(payload, context: context)
        // Both transports divert engine-blocking terminal commands and review-comment mutations to a
        // terminal-control lane before they reach here (see `runsOnTerminalControlLane`), so this case
        // only keeps the switch exhaustive.
        case .terminalControl, .terminalPasteImage, .sendTerminalInput, .state, .workspaceReviewCommentsSend, .workspaceReviewCommentUpsert,
            .workspaceReviewCommentDelete:
            return try handleTerminalControlLaneRequest(request)
        case .tailTerminalOutput(let payload): return try handleTailTerminalOutputRequest(payload)
        case .terminalTranscript(let payload): return try handleTerminalTranscriptRequest(payload)
        case .resolveTerminalLink(let payload): return try handleResolveTerminalLinkRequest(payload, context: context)
        case .readTerminalLinkChunk(let payload): return try handleReadTerminalLinkChunkRequest(payload)
        case .subscribe, .subscribeDeviceOverview, .subscribeWorkspaceDiffSignature, .subscribeWorkspaceFileSignature,
            .subscribeWorkspaceFileListSignature:
            return SpacesDeviceAPIResponse(ok: false, message: "Subscription requests must use the stream path.", errorCode: .misroutedRequest)
        case .agentHooksStatus, .installAgentHooks: return try handleAgentHookRequest(request)
        case .spawnAgentSession(let payload): return try handleSpawnAgentSessionRequest(payload, context: context)
        case .listAgentSessions(let payload): return try handleListAgentSessionsRequest(payload, context: context)
        case .annotateAgentSession(let payload): return try handleAnnotateAgentSessionRequest(payload, context: context)
        case .killAgentSession(let payload): return try handleKillAgentSessionRequest(payload, context: context)
        case .openServiceTunnel:
            // Hijacks the connection into a raw byte pipe after this response, like a subscription;
            // it cannot be answered on the request/response path handled here.
            return SpacesDeviceAPIResponse(ok: false, message: "Tunnel requests must use the tunnel path.", errorCode: .misroutedRequest)
        case .createAutomation(let payload): return try handleCreateAutomationRequest(payload)
        case .updateAutomation(let payload): return try handleUpdateAutomationRequest(payload)
        case .setAutomationNextRun(let payload): return try handleSetAutomationNextRunRequest(payload)
        case .deleteAutomation(let payload): return try handleDeleteAutomationRequest(payload)
        case .listAutomations: return try handleListAutomationsRequest()
        case .listAutomationRuns(let payload): return try handleListAutomationRunsRequest(payload, context: context)
        case .triggerAutomation(let payload): return try handleTriggerAutomationRequest(payload, context: context)
        case .cancelAutomationRun(let payload): return try handleCancelAutomationRunRequest(payload, context: context)
        case .endAutomationAgents(let payload): return try handleEndAutomationAgentsRequest(payload, context: context)
        }
    }

    private func handleAgentHookRequest(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
        switch request.command {
        case .agentHooksStatus:
            return SpacesDeviceAPIResponse(
                ok: true, message: "Loaded agent hook status.", result: .agentHooksStatus(.init(agents: agentHookStatusLoader())))
        case .installAgentHooks(let payload): return try handleInstallAgentHooksRequest(payload)
        default: preconditionFailure("Only agent-hook commands run on the agent-hook queue.")
        }
    }

    #if canImport(Network) && canImport(Security)
        private func handleAgentHookRequestAsync(
            _ request: SpacesDeviceAPIRequest, completion: @escaping @Sendable (Result<SpacesDeviceAPIResponse, any Error>) -> Void
        ) {
            agentHookQueue.async { [weak self] in
                guard let self else { return }
                let result = Result { try self.handleAgentHookRequest(request) }
                self.queue.async { completion(result) }
            }
        }
    #endif

    #if os(Linux) && canImport(OpenSSL)
        private func handleAgentHookRequestOnWorkerQueue(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
            try agentHookQueue.sync { try handleAgentHookRequest(request) }
        }
    #endif

    /// Runs one workspace-teardown command (see `runsOnWorkspaceTeardownQueue`).
    ///
    /// The `RequestContext` is created here rather than passed in from `handleRequest` so its store and
    /// orchestrator are opened and used only on `workspaceTeardownQueue`, per the confinement rule: a
    /// `SQLiteStore` belongs to the queue that opened it. The workspace lifecycle lock inside the
    /// orchestrator still serializes this command against any other action on the same workspace.
    private func handleWorkspaceTeardownRequest(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
        let context = RequestContext { [self] store in deviceOrchestrator(store: store) }
        switch request.command {
        case .deleteProject(let payload): return try handleDeleteProjectRequest(payload, context: context)
        case .archiveWorkspace(let payload): return try handleArchiveWorkspaceRequest(payload, context: context)
        default: preconditionFailure("Only workspace-teardown commands (archive, delete) run on the workspace-teardown queue.")
        }
    }

    /// Runs `.stopWorkspace` (see `runsOnWorkspaceStopQueue`) on its own serial queue, confined the same
    /// way `handleWorkspaceTeardownRequest` and `handleWorkspaceSetupRequest` confine their stores: a
    /// request handled on one queue must not touch a `SQLiteStore` opened on another.
    private func handleWorkspaceStopRequest(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
        let context = RequestContext { [self] store in deviceOrchestrator(store: store) }
        switch request.command {
        case .stopWorkspace(let payload): return try handleStopWorkspaceRequest(payload, context: context)
        default: preconditionFailure("Only `.stopWorkspace` runs on the workspace-stop queue.")
        }
    }

    /// Runs `.runWorkspaceSetup` (see `runsOnWorkspaceSetupQueue`) on its own serial queue, confined the
    /// same way `handleWorkspaceTeardownRequest` confines its store and orchestrator, and for the same
    /// reason: setup and teardown never share a `RequestContext`, since a request handled on one queue
    /// must not touch a `SQLiteStore` opened on the other.
    private func handleWorkspaceSetupRequest(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
        let context = RequestContext { [self] store in deviceOrchestrator(store: store) }
        switch request.command {
        case .runWorkspaceSetup(let payload): return try handleRunWorkspaceSetupRequest(payload, context: context)
        default: preconditionFailure("Only `.runWorkspaceSetup` runs on the workspace-setup queue.")
        }
    }

    /// Runs one workspace file-read/write/diff/file-list/ref-list command (see `runsOnWorkspaceGitQueue`) on
    /// `workspaceGitQueue`, confined the same way the other per-family handlers above confine their store:
    /// a request handled on one queue must not touch a `SQLiteStore` opened on another.
    private func handleWorkspaceGitRequest(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
        let context = RequestContext { [self] store in deviceOrchestrator(store: store) }
        switch request.command {
        case .workspaceFileRead(let payload): return try handleWorkspaceFileReadRequest(payload, context: context)
        case .workspaceRevisionFileRead(let payload): return try handleWorkspaceRevisionFileReadRequest(payload, context: context)
        case .workspaceFileWrite(let payload): return try handleWorkspaceFileWriteRequest(payload, context: context)
        case .workspaceDiffManifestChunk(let payload): return try handleWorkspaceDiffManifestChunkRequest(payload, context: context)
        case .workspaceDiffManifestRelease(let payload): return handleWorkspaceDiffManifestReleaseRequest(payload)
        case .workspaceDiffFileChunk(let payload): return try handleWorkspaceDiffFileChunkRequest(payload, context: context)
        case .workspaceFileList(let payload): return try handleWorkspaceFileListRequest(payload, context: context)
        case .workspaceRefList(let payload): return try handleWorkspaceRefListRequest(payload, context: context)
        default: preconditionFailure("Only workspace file-read/write/diff/file-list/ref-list commands run on the workspace-git queue.")
        }
    }

    /// Publishes `workspaceIDs` as being torn down for the duration of `teardown`, so an overview built
    /// while it runs reports them (see `SpacesDeviceOverviewPayload.workspaceIDsWithTeardownInFlight`).
    /// Registered before any teardown work starts and released in a `defer`, so a teardown that throws
    /// cannot leave a workspace reported as forever deleting.
    ///
    /// Registration happens inside the handler, after `workspaceTeardownQueue` dequeues the request, so a
    /// teardown queued behind an in-flight one waits without its ids registered and is absent from
    /// overviews until it starts. Accepted: the client that issued it marks the row locally for the whole
    /// mutation regardless, and the only misread is another client's timed-out request reconciling the
    /// still-listed workspace as a failed delete. That un-marks a row which disappears from the very next
    /// overview once the queued teardown runs, so it self-heals.
    private func withTeardownRegistered<T>(workspaceIDs: [String], teardown: () throws -> T) rethrows -> T {
        workspaceTeardownRegistry.register(workspaceIDs: workspaceIDs)
        defer { workspaceTeardownRegistry.release(workspaceIDs: workspaceIDs) }
        return try teardown()
    }

    #if canImport(Network) && canImport(Security)
        private func handleWorkspaceTeardownRequestAsync(
            _ request: SpacesDeviceAPIRequest, completion: @escaping @Sendable (Result<SpacesDeviceAPIResponse, any Error>) -> Void
        ) {
            workspaceTeardownQueue.async { [weak self] in
                guard let self else { return }
                let result = Result { try self.handleWorkspaceTeardownRequest(request) }
                self.queue.async { completion(result) }
            }
        }

        private func handleWorkspaceStopRequestAsync(
            _ request: SpacesDeviceAPIRequest, completion: @escaping @Sendable (Result<SpacesDeviceAPIResponse, any Error>) -> Void
        ) {
            workspaceStopQueue.async { [weak self] in
                guard let self else { return }
                let result = Result { try self.handleWorkspaceStopRequest(request) }
                self.queue.async { completion(result) }
            }
        }

        private func handleWorkspaceSetupRequestAsync(
            _ request: SpacesDeviceAPIRequest, completion: @escaping @Sendable (Result<SpacesDeviceAPIResponse, any Error>) -> Void
        ) {
            workspaceSetupQueue.async { [weak self] in
                guard let self else { return }
                let result = Result { try self.handleWorkspaceSetupRequest(request) }
                self.queue.async { completion(result) }
            }
        }

        private func handleStartWorkspaceCommandSessionAsync(
            _ request: SpacesDeviceAPIRequest, completion: @escaping @Sendable (Result<SpacesDeviceAPIResponse, any Error>) -> Void
        ) {
            workspaceTerminalLaunchQueue.async { [weak self] in
                guard let self else { return }
                let context = RequestContext { [self] store in deviceOrchestrator(store: store) }
                let result = Result {
                    guard case .startWorkspaceCommandSession(let payload) = request.command else {
                        preconditionFailure("Only `.startWorkspaceCommandSession` runs on the workspace-terminal-launch queue.")
                    }
                    return try self.handleStartWorkspaceCommandSessionRequest(payload, context: context)
                }
                self.queue.async { completion(result) }
            }
        }

        private func handleWorkspaceGitRequestAsync(
            _ request: SpacesDeviceAPIRequest, completion: @escaping @Sendable (Result<SpacesDeviceAPIResponse, any Error>) -> Void
        ) {
            let workspaceID = workspaceGitQueueWorkspaceID(for: request)
            let exists: Bool
            do { exists = try workspaceExistsForGitQueueRouting(workspaceID: workspaceID) } catch {
                completion(.failure(error))
                return
            }
            guard exists else {
                // Answered here, before `workspaceGitQueue(for:)` runs, so a nonexistent/spoofed workspace
                // id never mints an entry in `workspaceGitQueuesByWorkspaceID` (see that dictionary's doc
                // comment for the accepted remainder this still leaves for a genuinely-deleted workspace).
                completion(.success(SpacesDeviceAPIServer.failureResponse(for: Self.workspaceNotFoundError(workspaceID: workspaceID))))
                return
            }
            // Called already confined to `queue` (see `processBufferedLines`), so resolving (and, on first
            // use, creating) the per-workspace queue here is safe before hopping off `queue` to run the git
            // work itself.
            let targetQueue = workspaceGitQueue(for: workspaceID)
            targetQueue.async { [weak self] in
                guard let self else { return }
                let result = Result { try self.handleWorkspaceGitRequest(request) }
                self.queue.async { completion(result) }
            }
        }
    #endif

    #if os(Linux) && canImport(OpenSSL)
        private func handleWorkspaceTeardownRequestOnWorkerQueue(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
            try workspaceTeardownQueue.sync { try handleWorkspaceTeardownRequest(request) }
        }

        private func handleWorkspaceStopRequestOnWorkerQueue(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
            try workspaceStopQueue.sync { try handleWorkspaceStopRequest(request) }
        }

        private func handleWorkspaceSetupRequestOnWorkerQueue(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
            try workspaceSetupQueue.sync { try handleWorkspaceSetupRequest(request) }
        }

        private func handleStartWorkspaceCommandSessionOnWorkerQueue(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
            try workspaceTerminalLaunchQueue.sync {
                let context = RequestContext { [self] store in deviceOrchestrator(store: store) }
                guard case .startWorkspaceCommandSession(let payload) = request.command else {
                    preconditionFailure("Only `.startWorkspaceCommandSession` runs on the workspace-terminal-launch queue.")
                }
                return try handleStartWorkspaceCommandSessionRequest(payload, context: context)
            }
        }

        private func handleWorkspaceGitRequestOnWorkerQueue(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
            let workspaceID = workspaceGitQueueWorkspaceID(for: request)
            guard try workspaceExistsForGitQueueRouting(workspaceID: workspaceID) else {
                // Answered here, before `workspaceGitQueue(for:)` runs, so a nonexistent/spoofed workspace
                // id never mints an entry in `workspaceGitQueuesByWorkspaceID` (see that dictionary's doc
                // comment for the accepted remainder this still leaves for a genuinely-deleted workspace).
                return SpacesDeviceAPIServer.failureResponse(for: Self.workspaceNotFoundError(workspaceID: workspaceID))
            }
            // Unlike the macOS path above, this runs off `queue` (see the caller), so resolving the
            // per-workspace queue must itself hop onto `queue` rather than touching the dictionary directly.
            let targetQueue = try syncOnQueue { workspaceGitQueue(for: workspaceID) }
            return try targetQueue.sync { try handleWorkspaceGitRequest(request) }
        }
    #endif

    /// Runs one engine-blocking terminal command or Code pane review-comment mutation (see
    /// `runsOnTerminalControlLane`). Terminal handlers read session files and talk to a control socket;
    /// review-comment handlers open their own `SQLiteStore` because this request bypasses the
    /// queue-confined `RequestContext` created by `handleRequest`.
    private func handleTerminalControlLaneRequest(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
        switch request.command {
        case .terminalControl(let payload): return try handleTerminalControlRequest(payload)
        case .terminalPasteImage(let payload): return try handleTerminalPasteImageRequest(payload)
        case .sendTerminalInput(let payload): return try handleSendTerminalInputRequest(payload)
        case .state(let payload): return try handleStateRequest(payload)
        case .workspaceReviewCommentsSend(let payload): return try handleWorkspaceReviewCommentsSendRequest(payload)
        case .workspaceReviewCommentUpsert(let payload): return try handleWorkspaceReviewCommentUpsertRequest(payload)
        case .workspaceReviewCommentDelete(let payload): return try handleWorkspaceReviewCommentDeleteRequest(payload)
        default: preconditionFailure("Only engine-blocking terminal commands and review-comment mutations run on a terminal-control lane.")
        }
    }

    #if canImport(Network) && canImport(Security)
        private func handleTerminalControlRequestAsync(
            _ request: SpacesDeviceAPIRequest, completion: @escaping @Sendable (Result<SpacesDeviceAPIResponse, any Error>) -> Void
        ) {
            let sessionID = request.sessionID
            let lane = terminalControlLanes.retain(forSessionID: sessionID)
            let enqueuedAt = Self.laneWaitClock()
            lane.async { [weak self, terminalControlLanes] in
                // Released before anything can throw or return early, so a lane can never be stranded
                // holding a count for a request that already finished.
                defer { terminalControlLanes.release(forSessionID: sessionID) }
                guard let self else { return }
                self.logTerminalControlLaneWait(request, enqueuedAt: enqueuedAt)
                let result = Result { try self.handleTerminalControlLaneRequest(request) }
                self.queue.async { completion(result) }
            }
        }
    #endif

    #if os(Linux) && canImport(OpenSSL)
        private func handleTerminalControlRequestOnWorkerQueue(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
            let sessionID = request.sessionID
            let lane = terminalControlLanes.retain(forSessionID: sessionID)
            defer { terminalControlLanes.release(forSessionID: sessionID) }
            let enqueuedAt = Self.laneWaitClock()
            return try lane.sync {
                logTerminalControlLaneWait(request, enqueuedAt: enqueuedAt)
                return try handleTerminalControlLaneRequest(request)
            }
        }
    #endif

    /// The enqueue instant a lane-wait metric is measured from, and zero when the perf log is off. Reading
    /// the clock is the only cost this metric would impose on a normal build, and it sits on the path every
    /// keystroke takes, so a build that will never emit the metric does not pay for it.
    private static func laneWaitClock() -> UInt64 { TerminalPerformance.isEnabled ? DispatchTime.now().uptimeNanoseconds : 0 }

    /// How long this request waited for its session's control lane, measured enqueue-to-dequeue.
    ///
    /// Handler duration alone cannot tell a slow engine from a queued keystroke, and the queueing is what
    /// the per-session lanes exist to remove, so the wait is what has to be measurable to attribute a
    /// before/after. DEBUG-gated through `TerminalPerformance` like every other perf metric; the wait is
    /// routinely sub-millisecond, so the microsecond figure rides in `detail` where the millisecond field
    /// would round it to zero.
    private func logTerminalControlLaneWait(_ request: SpacesDeviceAPIRequest, enqueuedAt: UInt64) {
        guard TerminalPerformance.isEnabled else { return }
        let waitNanoseconds = DispatchTime.now().uptimeNanoseconds &- enqueuedAt
        TerminalPerformance.logMetric(
            "device_api_control_lane_wait", target: request.sessionID ?? "-", elapsedMS: Int(waitNanoseconds / 1_000_000), success: true,
            detail: "command=\(request.commandName) wait_us=\(waitNanoseconds / 1000)")
    }

    /// Idempotently installs Spaces lifecycle hooks for the requested agents into this daemon's home
    /// directory, then returns fresh status for every supported agent. Rejects an empty request.
    ///
    /// A per-agent failure is reported inside the payload rather than as a rejected request: agents are
    /// installed independently, and the caller has to learn which ones landed so it can record them and
    /// retry only the rest. Only a missing `spaces` CLI, which makes every hook unwritable, throws.
    private func handleInstallAgentHooksRequest(_ payload: SpacesDeviceInstallAgentHooksRequest) throws -> SpacesDeviceAPIResponse {
        guard !payload.kinds.isEmpty else {
            return SpacesDeviceAPIResponse(ok: false, message: "No coding agents specified.", errorCode: .invalidArgument)
        }
        let outcome = try agentHookInstallHandler(payload.kinds)
        let message =
            outcome.failures.isEmpty
            ? "Installed agent hooks." : "Installed agent hooks, except: \(outcome.failures.map(\.message).joined(separator: " "))"
        return SpacesDeviceAPIResponse(ok: true, message: message, result: .agentHooksInstall(outcome))
    }

    /// Refuses a request that reached its dispatch point after the server stopped. Must be called on the
    /// Device API queue, in the same critical section as the work it guards — `stop()` and
    /// `resetPairingsAndStop()` publish `acceptingRequests` there, so a check taken on any other queue,
    /// or in a separate hop, is only a snapshot of a state that can change before the work runs.
    ///
    /// The refusal reaches the client as a coded failure rather than a bare socket close: both transports
    /// already flatten a thrown error into `(ok: false, message:)` and then drop the connection, so this
    /// closes the connection exactly as the pre-dispatch admission check does while telling the client
    /// why. It maps through `errorCode(for:)`'s default to `.internalError`, which is the right shape: the
    /// request was well formed and the client should redial, not correct it.
    func admitOnQueue() throws { guard acceptingRequests else { throw AdmissionRefused() } }

    /// Thrown by `admitOnQueue`. A named type rather than a coded `NSError` because one transport has to
    /// recognize it: on Linux a plain request socket is never registered with the stop sweep, so its own
    /// thread must close it when admission is refused (see `LinuxServer.handleClient`). Everywhere else it
    /// is just another thrown error that the flatten points turn into a failure response.
    struct AdmissionRefused: LocalizedError { var errorDescription: String? { "The Spaces Device API stopped accepting requests." } }

    private func authorize(_ request: SpacesDeviceAPIRequest) throws {
        guard !request.command.isPairingCommand else { return }
        do { try pairingStore.authorize(clientApp: request.clientApp, authToken: request.authToken) } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            throw NSError(domain: "SpacesDeviceAPIServer", code: 401, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// Maps a thrown error to its wire failure category at the top-level flatten points, where a typed
    /// error collapses into `(ok:false, message:)`. `authorize` and `resolvedRunningProcessID` rewrap
    /// failures as `NSError(domain: "SpacesDeviceAPIServer")` carrying the HTTP-like status in `code`,
    /// so those codes drive the mapping directly; `SpacesDevicePairingError` and `AgentHookInstallerError`
    /// are likewise Device API-specific pre-checks. The classification shared with the profile transport
    /// (`SpacesDaemonErrorClassification.errorCode(_:)`, so a client sees one code for one cause regardless
    /// of transport) lives in `SpacesDeviceWireErrorClassification`.
    static func errorCode(for error: any Error) -> SpacesDeviceErrorCode {
        let nsError = error as NSError
        if nsError.domain == "SpacesDeviceAPIServer" {
            switch nsError.code {
            case 401: return .unauthorized
            case 400: return .invalidArgument
            case 404: return .notFound
            default: return .internalError
            }
        }
        if error is SpacesDevicePairingError { return .unauthorized }
        // The daemon's host is missing the Spaces CLI every hook command needs; the request was well
        // formed, so this is the host lacking a capability rather than a client mistake.
        if error is AgentHookInstallerError { return .capabilityMissing }
        return SpacesDeviceWireErrorClassification.errorCode(error)
    }

    static func failureResponse(for error: any Error) -> SpacesDeviceAPIResponse {
        let nsError = error as NSError
        // The "SpacesDeviceAPIServer" domain is this file's own typed-error convention (see
        // `errorCode(for:)`): every throw site in that domain sets `NSLocalizedDescriptionKey` to the exact
        // client-facing string it wants surfaced. Read that directly rather than falling through to
        // `String(describing:)`, whose default `NSError` rendering wraps the message in
        // `Error Domain=... Code=... "message" UserInfo={...}` instead of returning it bare. This only
        // narrows the fallback for our own domain — other error types (`LocalizedError` conformers, plain
        // Swift errors with no domain-specific convention) are unaffected and keep their existing rendering.
        let message: String
        if nsError.domain == "SpacesDeviceAPIServer", let explicit = nsError.userInfo[NSLocalizedDescriptionKey] as? String {
            message = explicit
        } else {
            message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        return SpacesDeviceAPIResponse(ok: false, message: message, errorCode: errorCode(for: error))
    }

    private func handleTerminalControlRequest(_ payload: SpacesDeviceTerminalControlRequest) throws -> SpacesDeviceAPIResponse {
        let sessionID = payload.sessionID
        let clientID = Self.normalizedClientID(payload.clientID)
        trace(
            "terminal_control_request source_session=\(sessionID) target_session=\(sessionID) client=\(clientID ?? payload.client?.id ?? "-") command=\(payload.action.rawValue)"
        )
        let terminalCommand = Self.terminalControlCommand(from: payload, clientID: clientID)
        if terminalCommand.requiresOwnerClientID, clientID == nil {
            return SpacesDeviceAPIResponse(ok: false, message: "Missing device client ID.", errorCode: .invalidArgument)
        }

        let startedAt = Date()
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' is not running.", errorCode: .sessionNotRunning)
        }
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' is not available.", errorCode: .sessionNotAvailable)
        }

        let attributes: [String: String] = [
            "action": payload.action.rawValue, "client_id": clientID ?? "nil", "owner_epoch": payload.ownerEpoch.map(String.init) ?? "nil",
        ]
        let terminalRequest = TerminalControlRequest(command: terminalCommand)
        let dispatchStartedAt = Date()
        logDeviceAPIPerformance(sessionID: sessionID, name: "terminal_control_dispatch_begin", attributes: attributes)
        let response = try TerminalControlClient.send(request: terminalRequest, socketPath: paths.controlSocketPath)
        let dispatchMS = TerminalPerformance.elapsedMS(since: dispatchStartedAt)
        var responseAttributes = attributes
        responseAttributes["ok"] = response.ok ? "1" : "0"
        responseAttributes["control_socket_ms"] = String(dispatchMS)
        logDeviceAPIPerformance(sessionID: sessionID, name: "terminal_control_dispatch_end", elapsedMS: dispatchMS, attributes: responseAttributes)
        TerminalPerformance.logMetric(
            "device_api_\(payload.action.rawValue)", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: response.ok)
        let sessionState = response.ok && terminalCommand.includesSessionStateOnSuccess ? try? loadCurrentState(sessionID: sessionID) : nil
        responseAttributes["include_session_state"] = sessionState == nil ? "0" : "1"
        logDeviceAPIPerformance(
            sessionID: sessionID, name: "terminal_control_response_ready", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            attributes: responseAttributes)
        // setSelection and readSelectionText carry their text on the control response rather than in
        // session state (they are not owner-gated view changes, so they never includeSessionStateOnSuccess);
        // surface it the same way sessionState surfaces above so mobile/remote clients receive it.
        let result: SpacesDeviceAPIResult? =
            sessionState.map(SpacesDeviceAPIResult.terminalState)
            ?? response.selectionText.map { SpacesDeviceAPIResult.terminalSelectionText(SpacesDeviceTerminalOutputResult(text: $0)) }
        return SpacesDeviceAPIResponse(ok: response.ok, message: response.message, errorCode: response.errorCode, result: result)
    }

    private static func terminalControlCommand(from payload: SpacesDeviceTerminalControlRequest, clientID: String?) -> TerminalControlCommand {
        switch payload.action {
        case .attach:
            .attach(TerminalControlAttachPayload(client: payload.client, attachmentMode: payload.attachmentMode, appearance: payload.appearance))
        case .detach: .detach(TerminalControlClientPayload(clientID: clientID))
        case .heartbeat: .heartbeat(TerminalControlClientPayload(clientID: clientID))
        case .takeover: .takeover(TerminalControlClientPayload(clientID: clientID))
        case .send:
            .send(
                TerminalControlSendPayload(
                    text: payload.text, bytes: nil, clientID: clientID, ownerEpoch: payload.ownerEpoch, appendNewline: payload.appendNewline,
                    asPaste: payload.asPaste))
        case .key: .key(TerminalControlKeyPayload(key: payload.key, clientID: clientID, ownerEpoch: payload.ownerEpoch))
        case .clearScreen: .clearScreen(TerminalControlOwnerPayload(clientID: clientID, ownerEpoch: payload.ownerEpoch))
        case .resize:
            .resize(
                TerminalControlResizePayload(
                    clientID: clientID, columns: payload.columns, rows: payload.rows, ownerEpoch: payload.ownerEpoch,
                    resizeSerial: payload.resizeSerial))
        case .scroll:
            .scroll(
                TerminalControlScrollPayload(
                    clientID: clientID, ownerEpoch: payload.ownerEpoch, scrollHorizontal: payload.scrollHorizontal,
                    scrollVertical: payload.scrollVertical, scrollMods: payload.scrollMods, scrollPointerX: payload.scrollPointerX,
                    scrollPointerY: payload.scrollPointerY, scrollPointerMods: payload.scrollPointerMods))
        case .mouseButton:
            .mouseButton(
                TerminalControlMouseButtonPayload(
                    clientID: clientID, ownerEpoch: payload.ownerEpoch, button: payload.mouseButton, pressed: payload.mousePressed,
                    pointerX: payload.mousePointerX, pointerY: payload.mousePointerY, pointerMods: payload.mousePointerMods))
        case .setAppearance: .setAppearance(TerminalControlSetAppearancePayload(clientID: clientID, appearance: payload.appearance))
        case .setSelection:
            .setSelection(
                TerminalControlSetSelectionPayload(
                    clientID: clientID, startColumn: payload.selectionStartColumn, startRow: payload.selectionStartRow,
                    endColumn: payload.selectionEndColumn, endRow: payload.selectionEndRow, rectangle: payload.selectionRectangle))
        case .clearSelection: .clearSelection(TerminalControlClientPayload(clientID: clientID))
        case .readSelectionText: .readSelectionText(TerminalControlClientPayload(clientID: clientID))
        }
    }

    /// Agent-facing one-shot input: token-authorized like every command but deliberately not
    /// attachment- or owner-epoch-gated, because orchestrator agents write into sessions they never
    /// attach to or render. Mirrors the local profile `terminalSend` contract.
    private func handleSendTerminalInputRequest(_ payload: SpacesDeviceTerminalInputRequest) throws -> SpacesDeviceAPIResponse {
        let sessionID = payload.sessionID
        let hasText = payload.text != nil
        let hasBytes = payload.bytes != nil
        guard hasText || hasBytes else {
            return SpacesDeviceAPIResponse(ok: false, message: "text or bytes is required.", errorCode: .invalidArgument)
        }
        guard !(hasText && hasBytes) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Provide text or bytes, not both.", errorCode: .invalidArgument)
        }

        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' is not running.", errorCode: .sessionNotRunning)
        }
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' is not available.", errorCode: .sessionNotAvailable)
        }
        let response = try TerminalControlClient.send(
            request: TerminalControlRequest(
                command: .send(
                    TerminalControlSendPayload(
                        text: payload.text, bytes: payload.bytes, clientID: nil, ownerEpoch: nil, appendNewline: payload.appendNewline))),
            socketPath: paths.controlSocketPath)
        return SpacesDeviceAPIResponse(ok: response.ok, message: response.message, errorCode: response.errorCode)
    }

    /// Agent-facing rendered tail of the session's output log, mirroring the local profile
    /// `terminalTail` contract (VT replay through `TerminalOutputTail`).
    private func handleTailTerminalOutputRequest(_ payload: SpacesDeviceTerminalTailRequest) throws -> SpacesDeviceAPIResponse {
        let sessionID = payload.sessionID
        let lineCount = max(payload.lines ?? 20, 1)
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.outputPath) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' has no output yet.", errorCode: .sessionNotAvailable)
        }
        let output = try TerminalOutputTail.tail(path: paths.outputPath, lineCount: lineCount)
        return SpacesDeviceAPIResponse(ok: true, message: "Read terminal output.", result: .terminalOutput(.init(text: output)))
    }

    /// Read-only suffix of the session's persisted output transcript, for client-local ended-session
    /// scrollback replay. Not interactivity-gated: it exposes the same append-only `output.log` bytes
    /// `tailTerminalOutput` already renders, and an ended session is exactly when this is needed. The
    /// returned suffix is capped at the smaller of the requested size and the scrollback budget.
    private func handleTerminalTranscriptRequest(_ payload: SpacesDeviceTerminalTranscriptRequest) throws -> SpacesDeviceAPIResponse {
        let sessionID = payload.sessionID
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.outputPath) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' has no output yet.", errorCode: .sessionNotAvailable)
        }
        let cap = min(max(payload.maxBytes, 0), TerminalScrollbackBudget.defaultMaxBytes)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: paths.outputPath))
        defer { try? handle.close() }
        let totalBytes = try handle.seekToEnd()
        let startOffset = totalBytes > UInt64(cap) ? totalBytes - UInt64(cap) : 0
        try handle.seek(toOffset: startOffset)
        // Bound the read to the size snapshot: `output.log` is append-only, so this range always
        // exists, and a still-running session appending past `totalBytes` cannot grow the response
        // beyond the cap (this command is deliberately not interactivity-gated).
        var data = try handle.read(upToCount: Int(totalBytes - startOffset)) ?? Data()
        // A capped suffix starts at an arbitrary byte, which can split a UTF-8 character or an
        // escape sequence and replay as garbage. Advance to the first line boundary so the replay
        // starts on whole lines; a suffix with no newline at all is returned raw (the vt parser
        // resynchronizes, at worst mangling the oldest visible scrollback line).
        // Accepted limitation: a suffix cut inside established VT state (an alternate-screen session,
        // a persistent SGR color) replays with default terminal state — faithfully restoring it would
        // require reconstructing terminal state from the dropped prefix, which capped replay deliberately
        // does not do. The newest scrollback is unaffected.
        if startOffset > 0, let newlineIndex = data.firstIndex(of: 0x0A), newlineIndex < data.endIndex - 1 {
            data = data.subdata(in: (newlineIndex + 1)..<data.endIndex)
        }
        // Carry the current run's identity so the client can reject a fetch that straddled a relaunch:
        // a relaunch truncates `output.log`, so bytes read here could belong to a newer run than the one
        // the client's replay was armed against. `nil` when no runtime state exists yet.
        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        return SpacesDeviceAPIResponse(
            ok: true, message: "Read terminal transcript.",
            result: .terminalTranscript(.init(data: data, totalBytes: totalBytes, runIdentity: runtimeState?.runIdentity)))
    }

    private func handleTerminalPasteImageRequest(_ payload: SpacesDeviceTerminalPasteImageRequest) throws -> SpacesDeviceAPIResponse {
        let startedAt = Date()
        let sessionID = payload.sessionID
        let clientID = Self.normalizedClientID(payload.clientID)
        guard let clientID else { return SpacesDeviceAPIResponse(ok: false, message: "Missing device client ID.", errorCode: .invalidArgument) }
        guard !payload.imageData.isEmpty else {
            return SpacesDeviceAPIResponse(ok: false, message: "Missing image payload.", errorCode: .invalidArgument)
        }
        guard payload.imageData.count <= Self.terminalPasteImageMaxBytes else {
            return SpacesDeviceAPIResponse(ok: false, message: "Image payload exceeds the 10 MiB limit.", errorCode: .payloadTooLarge)
        }
        let fileExtension = Self.normalizedPasteImageExtension(payload.fileExtension)
        guard let fileExtension else {
            return SpacesDeviceAPIResponse(ok: false, message: "Unsupported image file extension.", errorCode: .unsupportedFormat)
        }

        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' is not running.", errorCode: .sessionNotRunning)
        }
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' is not available.", errorCode: .sessionNotAvailable)
        }
        guard let snapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths),
            TerminalRemoteSessionStatePolicy.activeOwnerClientID(in: snapshot) == clientID
        else {
            return SpacesDeviceAPIResponse(
                ok: false, message: "Only the active owner can paste images into the terminal.", errorCode: .ownershipRejected)
        }
        // Epoch-gate only when the client sent an epoch: a request without one is not stale, it was
        // composed by a client whose cached session payload carries no render owner epoch (the same
        // contract the other input paths follow).
        if let requestedOwnerEpoch = payload.ownerEpoch,
            let ownerEpoch = (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))?.renderOwnerEpoch,
            ownerEpoch != requestedOwnerEpoch
        {
            return SpacesDeviceAPIResponse(
                ok: false, message: "Ignoring stale owner epoch \(requestedOwnerEpoch); current owner epoch is \(ownerEpoch).",
                errorCode: .ownershipRejected)
        }

        let remotePath = "/tmp/spaces-paste-\(UUID().uuidString).\(fileExtension)"
        try Self.writeUserOnlyPasteImage(payload.imageData, toPath: remotePath)
        let terminalRequest = TerminalControlRequest(
            command: .send(
                TerminalControlSendPayload(
                    text: remotePath, bytes: nil, clientID: clientID, ownerEpoch: payload.ownerEpoch, appendNewline: false, asPaste: true)))
        let response: TerminalControlResponse
        do { response = try TerminalControlClient.send(request: terminalRequest, socketPath: paths.controlSocketPath) } catch {
            try? FileManager.default.removeItem(atPath: remotePath)
            throw error
        }
        if !response.ok { try? FileManager.default.removeItem(atPath: remotePath) }
        TerminalPerformance.logMetric(
            "device_api_terminalPasteImage", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: response.ok, detail: "bytes=\(payload.imageData.count) extension=\(fileExtension)")
        return SpacesDeviceAPIResponse(ok: response.ok, message: response.ok ? "Pasted image path." : response.message)
    }

    private static func normalizedClientID(_ value: String?) -> String? {
        guard let clientID = value?.trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty else { return nil }
        return clientID
    }

    private static func normalizedPasteImageExtension(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)).lowercased()
        guard !normalized.isEmpty, terminalPasteImageExtensions.contains(normalized) else { return nil }
        return normalized
    }

    private static func writeUserOnlyPasteImage(_ data: Data, toPath path: String) throws {
        let fileDescriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = write(fileDescriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                    guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += written
                }
            }
            close(fileDescriptor)
        } catch {
            close(fileDescriptor)
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
    }

    // Frozen-core daemon status: wire protocol numbers plus the restart-impact counts a daemon
    // restart would destroy. This standalone path runs its own store scan so it works even when the
    // rest of the protocol is incompatible (the only time a client issues it). The compatible steady
    // state never reaches here — the same status rides inline on the overview (see `loadOverview`).
    private func loadDaemonStatus() throws -> TerminalServiceDaemonStatus {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        var impact = RestartImpactCounts()
        for project in try store.projects() {
            for workspace in try store.workspaces(projectID: project.id) {
                impact.accumulate(
                    runningProcesses: try store.runningProcesses(workspaceID: workspace.id),
                    agentWindows: try store.agentWindows(workspaceID: workspace.id))
            }
        }
        let liveTerminals = ((try? liveTerminalSessions()) ?? []).count
        return makeDaemonStatus(activeSessionCount: liveTerminals, impact: impact)
    }

    /// Restart-impact tallies a daemon restart would destroy. Shared by the standalone frozen-core
    /// `loadDaemonStatus` and the inline status attached to the overview so both report the same
    /// counts from whichever scan already loaded the records.
    private struct RestartImpactCounts {
        var runningProcesses = 0
        var activeAgents = 0
        var waitingAgents = 0

        mutating func accumulate(runningProcesses processes: [RunningProcessRecord], agentWindows: [AgentWindowRecord]) {
            runningProcesses += processes.filter { $0.status == .running }.count
            for agent in agentWindows {
                switch agent.status {
                case .spinning: activeAgents += 1
                case .waiting: waitingAgents += 1
                // Exited counts as no live agent work, like idle/done: a restart destroys nothing for it.
                case .idle, .done, .exited: break
                }
            }
        }
    }

    /// Returns a rejection message when a pairing client's wire-protocol version does not match this
    /// daemon's, or nil when it matches. Keeps the pairing gate symmetric with the client's
    /// pre-redeem check: whichever side is older is told to update.
    static func pairingVersionRejection(clientProtocolVersion: Int?) -> String? {
        let clientProtocolVersion = clientProtocolVersion ?? 0
        guard clientProtocolVersion != SpacesWireProtocol.version else { return nil }
        if clientProtocolVersion < SpacesWireProtocol.version {
            return "This device runs Spaces \(AppVersion.short); update Spaces on the pairing device to match, then pair again."
        }
        return "This device runs Spaces \(AppVersion.short), which is older than the pairing device; update Spaces on this device, then pair again."
    }

    // Instance method (not static) so it can read `self.host`: the daemon status this server reports
    // must advertise the same addresses a pairing link opened from this server would offer, derived
    // from the identical `pairingLinkHosts(boundHost:)` call.
    private func makeDaemonStatus(activeSessionCount: Int, impact: RestartImpactCounts) -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: AppVersion.current, installedVersion: InstalledSpacesVersion.current(), certificateFingerprint: nil,
            activeSessionCount: activeSessionCount, protocolVersion: SpacesWireProtocol.version, runningProcesses: impact.runningProcesses,
            activeAgents: impact.activeAgents, waitingAgents: impact.waitingAgents,
            timeZoneIdentifier: TerminalServiceDaemonStatus.currentTimeZoneIdentifier,
            deviceAPIAddresses: SpacesDeviceAPINetworkInterfaces.pairingLinkHosts(boundHost: host))
    }

    /// Builds the device overview. Request handlers pass their shared per-request `store` so a
    /// mutation reuses one store end-to-end; the off-request overview-stream `lineProvider` passes
    /// no store and opens its own on the `overviewStreamQueue`.
    private func loadOverview(store providedStore: SQLiteStore? = nil, clientApp: SpacesDeviceClientApp? = nil) throws -> SpacesDeviceOverviewPayload
    {
        if let overviewLoaderForTesting { return try overviewLoaderForTesting(clientApp) }
        let store = try providedStore ?? SQLiteStore(path: DatabaseLocator.defaultPath())
        let orchestrator = deviceOrchestrator(store: store)
        // The router port is a Mac-only concept (only the macOS client runs Caddy), so remote
        // daemons never seed one and this fallback yields the canonical `AppConfig.defaultRouterPort`.
        // The reported `assignedPort.url` is a client-facing host/origin identity; the Mac client
        // rewrites the port to its own live Caddy port before navigation.
        let routerPort = (try? orchestrator.appConfig().routerPort) ?? AppConfig.defaultRouterPort
        let projects = try store.projects()
        // Batch the plain per-workspace table reads into one full-table query each, grouped by
        // workspace, so building N descriptors costs a constant number of queries instead of O(N).
        // Each batch preserves the same ORDER BY and WHERE semantics as its per-workspace counterpart,
        // so the grouped values match `store.<x>(workspaceID:)` element-for-element.
        let runningProcessesByWorkspace = try store.runningProcessesByWorkspace()
        let agentWindowsByWorkspace = try store.agentWindowsByWorkspace()
        let windowsByWorkspace = try store.windowsByWorkspace()
        let portsByWorkspace = try store.workspacePortsNamedByWorkspace()
        let setupStateByWorkspace = try store.workspaceSetupStateByWorkspace()
        let workspaces = try projects.flatMap { project in
            try store.workspaces(projectID: project.id).map { workspace in
                let slug = SpacesProfile.workspaceHostSlug(
                    branch: workspace.branch, projectName: project.name, isGitRepo: project.isGitRepo, workspaceID: workspace.id)
                // `resolvedWorkspaceBrowserSessions` and `workspaceSettings` stay per-workspace on
                // purpose: they rebuild the workspace's env/runtime plan internally rather than reading a
                // single table, so batching them would require restructuring orchestrator env
                // construction (out of scope for this N+1 pass).
                let resolvedBrowserSessions = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
                let namedPorts = portsByWorkspace[workspace.id] ?? []
                return SpacesDeviceOverviewBuilder.WorkspaceDescriptor(
                    project: project, workspace: workspace, settings: try? orchestrator.workspaceSettings(workspaceID: workspace.id),
                    runningProcesses: runningProcessesByWorkspace[workspace.id] ?? [], agentWindows: agentWindowsByWorkspace[workspace.id] ?? [],
                    windows: windowsByWorkspace[workspace.id] ?? [],
                    assignedPorts: namedPorts.map {
                        SpacesDeviceAssignedPort(name: $0.name, port: $0.port, url: "http://\($0.name).\(slug).localhost:\(routerPort)")
                    },
                    environment: orchestrator.buildWorkspaceEnv(
                        project: project, workspace: workspace, namedPorts: namedPorts.map { (port: $0.port, name: $0.name) }),
                    resolvedBrowserSessions: resolvedBrowserSessions,
                    // Mirror `orchestrator.workspaceSetupState`, which returns a succeeded default when no
                    // `workspace_settings` row exists for the workspace.
                    setupState: setupStateByWorkspace[workspace.id]
                        ?? WorkspaceSetupState(status: .succeeded, errorMessage: nil, startedAt: nil, finishedAt: nil))
            }
        }
        let localSessions = try liveTerminalSessions()
        let sessions = mergedTerminalSessions(localSessions)
        // One query for the whole build: the alternative asked per row, and each answer opened its own
        // connection and JSON-decoded a ~36 KB payload to test a single field.
        let sessionIDsWithFinalRender = try TerminalSessionPersistence.sessionIDsWithFinalRender()
        let workspaceRows = loadWorkspaceTerminalRows(
            workspaces: workspaces, sessions: sessions, sessionIDsWithFinalRender: sessionIDsWithFinalRender)
        // Reuse the records the overview already scanned to tally restart impact, so the inline
        // handshake costs no extra store work on the refresh hot path.
        var impact = RestartImpactCounts()
        for descriptor in workspaces { impact.accumulate(runningProcesses: descriptor.runningProcesses, agentWindows: descriptor.agentWindows) }
        let daemonStatus = makeDaemonStatus(activeSessionCount: localSessions.count, impact: impact)
        let (automationSummaries, automationRunSummaries) = try loadAutomationOverview(store: store, liveSessions: localSessions)
        return SpacesDeviceOverviewBuilder.build(
            projects: projects, workspaces: workspaces, workspaceRows: workspaceRows, liveSessions: sessions,
            workspaceIDsWithTeardownInFlight: workspaceTeardownRegistry.snapshot(), daemonStatus: daemonStatus, automations: automationSummaries,
            automationRuns: automationRunSummaries, automationAttributedSessionIDs: try store.terminalSessionIDsAttributedToExistingAutomationRuns())
    }

    /// Builds the overview's automation section: every automation, plus the runs a client needs — all
    /// currently-active (queued/running) runs unioned with the newest `recentAutomationRunLimit` terminal
    /// runs and each automation's latest terminal run, newest first, de-duplicated. Each run summary carries its automation name and its attributed
    /// coding-agent breakdown (computed against the live-session set the overview already scanned), so a
    /// client can render run history and derive alert entries without extra calls.
    private func loadAutomationOverview(store: SQLiteStore, liveSessions: [TerminalSessionCatalogEntry]) throws -> (
        [TerminalServiceAutomationSummary], [TerminalServiceAutomationRunSummary]
    ) {
        let automations = try store.automations()
        let automationSummaries = automations.map(TerminalServiceAutomationSummary.init)
        let namesByAutomationID = Dictionary(automations.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        // Active runs are always included regardless of the recent window; the recent terminal window fills
        // in history, and each automation's latest terminal run is unioned in so a chatty automation can't
        // evict quieter automations' last-run status. The selection contract lives in a pure builder helper
        // so it can be unit-tested.
        let ordered = SpacesDeviceOverviewBuilder.selectOverviewRuns(
            recentTerminal: try store.terminalAutomationRuns(limit: SpacesDeviceOverviewBuilder.recentAutomationRunLimit),
            latestPerAutomation: try store.latestTerminalAutomationRunPerAutomation(), active: try store.activeAutomationRuns())
        let attributedAgentsByRunID = try AutomationAttributedAgents.summariesByRunID(runs: ordered, store: store, liveSessions: liveSessions)
        let workspaceIDsByRunID = try store.workspaceIDs(automationRunIDs: ordered.map(\.id))
        let runSummaries = ordered.map { run in
            TerminalServiceAutomationRunSummary(
                run, automationName: namesByAutomationID[run.automationID], workspaceID: workspaceIDsByRunID[run.id],
                attributedAgents: attributedAgentsByRunID[run.id] ?? [])
        }
        return (automationSummaries, runSummaries)
    }

    /// The live-session listing every Device API endpoint below reads instead of calling
    /// `TerminalSessionCatalog.listLiveSessions()` directly, so all of them see the same in-memory merge.
    /// The merge itself lives on `TerminalSessionCatalog` (spacesterminalcore) rather than here so
    /// `SpacesdMain`, which imports `spacesdeviceapi` only conditionally, can share it too.
    private func liveTerminalSessions() throws -> [TerminalSessionCatalogEntry] {
        TerminalSessionCatalog.mergingLiveInMemorySessions(
            try TerminalSessionCatalog.listLiveSessions(), inMemory: liveInMemoryTerminalSessionsProvider?() ?? [])
    }

    private func mergedTerminalSessions(_ sessions: [TerminalSessionCatalogEntry]) -> [TerminalSessionCatalogEntry] {
        var order: [String] = []
        var entriesByID: [String: TerminalSessionCatalogEntry] = [:]
        for session in sessions {
            if entriesByID[session.sessionID] == nil { order.append(session.sessionID) }
            entriesByID[session.sessionID] = session
        }
        return order.compactMap { entriesByID[$0] }
    }

    /// Builds the per-workspace terminal rows for the overview. The descriptors already carry the exact
    /// records this needs — `descriptor.runningProcesses`/`descriptor.agentWindows` are populated in
    /// `loadOverview` from the same store queries — so this reuses them instead of re-querying per
    /// workspace, which otherwise doubled the process/agent reads on the refresh hot path.
    private func loadWorkspaceTerminalRows(
        workspaces: [SpacesDeviceOverviewBuilder.WorkspaceDescriptor], sessions: [TerminalSessionCatalogEntry], sessionIDsWithFinalRender: Set<String>
    ) -> [SpacesDeviceOverviewBuilder.WorkspaceTerminalRow] {
        Self.workspaceTerminalRows(
            workspaces: workspaces, sessions: sessions, sessionIDsWithFinalRender: sessionIDsWithFinalRender,
            catalogEntry: { terminalCatalogEntry(sessionID: $0) },
            endedWindowSessions: Self.endedTerminalWindowSessions(workspaces: workspaces, liveSessions: sessions))
    }

    /// The ended sessions still held by a terminal-window record, read in one query for the whole build.
    ///
    /// The window walk in `workspaceTerminalRows` needs each such session's persisted launch configuration
    /// and runtime state, and there is one candidate per terminal window whose session has exited. Reading
    /// them per row would put two connection round-trips per candidate on a build that runs several times a
    /// second, on the profile database's serialized lane — the lane every mutation also waits behind. One
    /// batched read keeps the cost flat, and a device whose held sessions are all still running issues no
    /// query at all.
    ///
    /// An ended session's attachment snapshot is empty by construction: exiting detaches every client, and
    /// the ended pane a client shows is client-local and holds no attachment. So the entry is built with an
    /// empty snapshot and no live control/subscription rather than paying a query to read that back — the
    /// builder forces both availability flags false for a non-interactive session anyway.
    private static func endedTerminalWindowSessions(
        workspaces: [SpacesDeviceOverviewBuilder.WorkspaceDescriptor], liveSessions: [TerminalSessionCatalogEntry]
    ) -> [String: TerminalSessionCatalogEntry] {
        let liveSessionIDs = Set(liveSessions.map(\.sessionID))
        var candidates = Set<String>()
        for descriptor in workspaces {
            for window in descriptor.windows where window.roleValue == .terminal {
                guard let sessionID = normalizedTerminalSessionID(window.terminalTrackingID), !liveSessionIDs.contains(sessionID) else { continue }
                candidates.insert(sessionID)
            }
        }
        guard let runtimes = try? TerminalSessionPersistence.endedSessionRuntimes(sessionIDs: candidates) else { return [:] }
        return Dictionary(
            runtimes.compactMap { runtime -> (String, TerminalSessionCatalogEntry)? in
                guard let paths = try? TerminalSessionPaths.forStoredSession(id: runtime.sessionID, rootDirectory: runtime.rootDirectory) else {
                    return nil
                }
                return (
                    runtime.sessionID,
                    TerminalSessionCatalogEntry(
                        launchConfiguration: runtime.launchConfiguration, runtimeState: runtime.runtimeState, attachmentSnapshot: .init(),
                        paths: paths, isControlAvailable: false, isSubscriptionAvailable: false)
                )
            }, uniquingKeysWith: { existing, _ in existing })
    }

    /// One row per product record that holds a terminal session — a `running_processes`, `agent_sessions`,
    /// or terminal `runtime_targets` row — carrying that session's full catalog entry.
    ///
    /// `catalogEntry` is the persisted lookup (`terminalCatalogEntry`) used whenever `sessions`, the live
    /// interactive catalog, does not carry the session. That is what keeps a session describable after it
    /// exits: its entry is what `sessions` publishes, and a pane cannot be opened for a session whose
    /// launch configuration nothing reports. All three record kinds resolve through it, so all three keep
    /// their ended sessions openable for exactly as long as the retention rule
    /// (`SpacesDeviceOverviewPayload.retainedTerminalSessionIDs`) holds them — the behavior `docs/spec.md`
    /// describes for an exited target, whichever kind of row backs it.
    ///
    /// `endedWindowSessions` is the batched counterpart for the terminal-window walk below
    /// (`endedTerminalWindowSessions`): every candidate it needs is known before the walk starts, so they
    /// are read together instead of one row at a time.
    ///
    /// Static and taking both lookups as parameters so the whole rule is exercisable without a running
    /// daemon or on-disk sessions.
    static func workspaceTerminalRows(
        workspaces: [SpacesDeviceOverviewBuilder.WorkspaceDescriptor], sessions: [TerminalSessionCatalogEntry],
        sessionIDsWithFinalRender: Set<String>, catalogEntry: (String) -> TerminalSessionCatalogEntry?,
        endedWindowSessions: [String: TerminalSessionCatalogEntry]
    ) -> [SpacesDeviceOverviewBuilder.WorkspaceTerminalRow] {
        var rows: [SpacesDeviceOverviewBuilder.WorkspaceTerminalRow] = []
        var representedSessionIDs = Set<String>()
        let sessionsByID = Dictionary(sessions.map { ($0.sessionID, $0) }, uniquingKeysWith: { existing, _ in existing })
        for descriptor in workspaces {
            let processesBySlot = Dictionary(grouping: descriptor.runningProcesses, by: { processSlotKey($0) })
            for process in processesBySlot.values.compactMap(preferredProcessRecord).sorted(by: {
                $0.templateName.localizedStandardCompare($1.templateName) == .orderedAscending
            }) {
                guard process.terminalApp == TerminalHost.spaces.appName, let sessionID = normalizedTerminalSessionID(process.terminalTrackingID)
                else { continue }
                guard representedSessionIDs.insert(sessionID).inserted else { continue }
                guard let entry = sessionsByID[sessionID] ?? catalogEntry(sessionID) else { continue }
                rows.append(
                    SpacesDeviceOverviewBuilder.WorkspaceTerminalRow(
                        entry: entry, workspace: descriptor, title: process.templateName, rowKind: .process, rowSourceID: process.id,
                        hasFinalRender: sessionIDsWithFinalRender.contains(sessionID)))
            }

            let agentsBySlot = Dictionary(grouping: descriptor.agentWindows, by: { agentSlotKey($0) })
            for agent in agentsBySlot.values.compactMap(preferredAgentRecord).sorted(by: {
                ($0.effectiveLabel ?? "").localizedStandardCompare($1.effectiveLabel ?? "") == .orderedAscending
            }) {
                guard agent.provider == .spaces, let sessionID = normalizedTerminalSessionID(agent.terminalTrackingID) else { continue }
                guard representedSessionIDs.insert(sessionID).inserted else { continue }
                guard let entry = sessionsByID[sessionID] ?? catalogEntry(sessionID) else { continue }
                rows.append(
                    SpacesDeviceOverviewBuilder.WorkspaceTerminalRow(
                        entry: entry, workspace: descriptor, title: agent.effectiveLabel ?? entry.name, rowKind: .agent, rowSourceID: agent.id,
                        hasFinalRender: sessionIDsWithFinalRender.contains(sessionID)))
            }

            // A terminal window's own row. Only sessions the live catalog does not already carry: a live
            // one is published as an ad hoc summary, which is where a shell's `liveTitle` reaches clients
            // (a window row's summary carries none), so claiming it here would drop what the program
            // prints. What is left is the ended-but-held session, the case the process and agent loops
            // above already cover through the same lookup.
            for window in descriptor.windows where window.roleValue == .terminal {
                guard let sessionID = normalizedTerminalSessionID(window.terminalTrackingID), sessionsByID[sessionID] == nil else { continue }
                guard representedSessionIDs.insert(sessionID).inserted else { continue }
                guard let entry = endedWindowSessions[sessionID] else { continue }
                rows.append(
                    SpacesDeviceOverviewBuilder.WorkspaceTerminalRow(
                        entry: entry, workspace: descriptor, title: entry.name, rowKind: .liveSession, rowSourceID: window.id,
                        hasFinalRender: sessionIDsWithFinalRender.contains(sessionID)))
            }
        }
        return rows
    }

    private static func preferredProcessRecord(_ records: [RunningProcessRecord]) -> RunningProcessRecord? {
        records.max { lhs, rhs in
            let lhsRank = processRecordRank(lhs)
            let rhsRank = processRecordRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return (lhs.startedAt ?? lhs.exitedAt ?? "") < (rhs.startedAt ?? rhs.exitedAt ?? "")
        }
    }

    private static func processRecordRank(_ record: RunningProcessRecord) -> Int {
        switch record.status {
        case .running: return 3
        case .idle: return 2
        case .exited: return 1
        }
    }

    private static func preferredAgentRecord(_ records: [AgentWindowRecord]) -> AgentWindowRecord? {
        records.max { lhs, rhs in
            let lhsRank = agentRecordRank(lhs)
            let rhsRank = agentRecordRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    private static func agentRecordRank(_ record: AgentWindowRecord) -> Int {
        if record.provider == .spaces, let sessionID = normalizedTerminalSessionID(record.terminalTrackingID),
            let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            (try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.state.isInteractive == true
        {
            return 4
        }
        switch record.status {
        case .spinning: return 3
        case .waiting: return 2
        case .idle: return 1
        // Exited agents (process gone, terminal alive) sort to the bottom alongside done.
        case .done, .exited: return 0
        }
    }

    private static func processSlotKey(_ record: RunningProcessRecord) -> String {
        if let templateID = record.templateID?.trimmingCharacters(in: .whitespacesAndNewlines), !templateID.isEmpty {
            return "process-id:\(templateID)"
        }
        return "process:\(normalizedSlotName(record.templateName))"
    }

    private static func agentSlotKey(_ record: AgentWindowRecord) -> String {
        // The slot name has to be the name the row displays: a rename frees the raw label for a new agent
        // to register under, and keying on it would collapse two live agents into one slot.
        "agent:\(normalizedSlotName(record.effectiveLabel ?? record.id))"
    }

    private static func normalizedSlotName(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private func terminalCatalogEntry(sessionID: String, fileManager: FileManager = .default) -> TerminalSessionCatalogEntry? {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths),
            let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        else { return nil }
        guard !runtimeState.state.isInteractive || TerminalSessionCatalog.isInteractiveServiceAlive(for: runtimeState) else { return nil }
        let attachmentSnapshot = ((try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? .init()).liveWireProjection()
        return TerminalSessionCatalogEntry(
            launchConfiguration: launchConfiguration, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot, paths: paths,
            isControlAvailable: fileManager.fileExists(atPath: paths.controlSocketPath),
            isSubscriptionAvailable: fileManager.fileExists(atPath: paths.subscriptionSocketPath))
    }

    private static func normalizedTerminalSessionID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// The window opener is a no-op for every Device API request: the caller may be an iPhone, another
    /// Mac, or the local app itself, and a request arriving over the wire is never authority to open a
    /// pane on this machine's desktop. Clients that want a pane ask for one themselves once the
    /// mutation's refreshed overview comes back.
    ///
    /// `deliversTerminalWindowOpens: false` follows from that and has to be stated, because the closer is
    /// wired independently and does post real IPC. Without it a restart served here would close a pane as
    /// held for a replacement whose open this orchestrator can never send, and the client would keep
    /// showing the terminated session forever.
    private func deviceOrchestrator(store: SQLiteStore) -> WorkspaceOrchestrator {
        WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _, _ in }, deliversTerminalWindowOpens: false,
            builtInTerminalSessionTerminator: builtInTerminalSessionTerminator, builtInTerminalSessionLauncher: builtInTerminalSessionLauncher)
    }

    private func finishReservedWorkspaceTerminalLaunchInBackground(_ reservation: WorkspaceOrchestrator.WorkspaceTerminalLaunchReservation) {
        let launcher = builtInTerminalSessionLauncher
        let terminator = builtInTerminalSessionTerminator
        let traceEnabled = traceEnabled
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                let orchestrator = WorkspaceOrchestrator(
                    store: store, builtInTerminalWindowOpener: { _, _, _ in }, deliversTerminalWindowOpens: false,
                    builtInTerminalSessionTerminator: terminator, builtInTerminalSessionLauncher: launcher)
                try orchestrator.finishReservedWorkspaceTerminalLaunch(reservation)
            } catch {
                guard traceEnabled else { return }
                let message = String(describing: error).replacingOccurrences(of: "\n", with: "\\n")
                FileHandle.standardOutput.write(
                    Data(
                        "spaces-device-api-trace workspace_terminal_background_launch_error session=\(reservation.sessionID) error=\(message)\n".utf8)
                )
            }
        }
    }

    private func handleWorkspaceCreateOptionsRequest(_ request: SpacesDeviceWorkspaceCreateOptionsRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let store = try context.store()
        let orchestrator = try context.orchestrator()
        // Hidden projects are not offered for workspace creation: a workspace created under one would
        // be invisible on every browsing surface the moment it exists. The Workspaces dialog is where
        // a hidden project comes back; creation under it becomes available again once it is unhidden.
        let projects = try store.projects().filter { !$0.isHidden }.map {
            SpacesDeviceProjectSummary(
                id: $0.id, name: $0.name, dir: $0.dir, isGitRepo: $0.isGitRepo, defaultBranch: $0.defaultBranch, isHidden: $0.isHidden)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Resolve the requested selection against the offered list, so a stale client request naming a
        // hidden (or deleted) project falls back to a visible default instead of pre-selecting a
        // project the picker does not show.
        let requestedProjectID = normalizedString(request.projectID)
        let selectedProjectID = requestedProjectID.flatMap { id in projects.contains(where: { $0.id == id }) ? id : nil } ?? projects.first?.id
        let branchOptions: [String]
        if let selectedProjectID, let project = try store.project(id: selectedProjectID), project.isGitRepo {
            branchOptions = try orchestrator.gitBranchOptions(projectID: selectedProjectID)
        } else {
            branchOptions = []
        }
        return SpacesDeviceAPIResponse(
            ok: true, message: "Loaded workspace create options.",
            result: .workspaceCreateOptions(
                SpacesDeviceWorkspaceCreateOptions(projects: projects, selectedProjectID: selectedProjectID, branchOptions: branchOptions)))
    }

    private func handlePreviewProjectRequest(_ request: SpacesDeviceProjectPreviewRequest, context: RequestContext) throws -> SpacesDeviceAPIResponse
    {
        guard let dir = normalizedString(request.dir) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Provide a project directory.", errorCode: .invalidArgument)
        }
        let project = try context.orchestrator().previewProject(dir: dir)
        let preview = SpacesDeviceProjectPreview(
            name: project.name, dir: project.dir, isGitRepo: project.isGitRepo, defaultBranch: project.defaultBranch,
            config: SpacesDeviceOverviewBuilder.projectConfig(from: project))
        return SpacesDeviceAPIResponse(ok: true, message: "Loaded project preview.", result: .projectPreview(preview))
    }

    private func handleListDirectoriesRequest(_ request: SpacesDeviceDirectoryListRequest) throws -> SpacesDeviceAPIResponse {
        let paths = Self.directorySuggestions(forPartialPath: request.path)
        return SpacesDeviceAPIResponse(
            ok: true, message: "Loaded directory suggestions.", result: .directorySuggestions(SpacesDeviceDirectorySuggestions(paths: paths)))
    }

    static func directorySuggestions(forPartialPath partial: String, limit: Int = 20) -> [String] {
        let trimmed = partial.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let usesTilde = trimmed == "~" || trimmed.hasPrefix("~/")
        let home = NSHomeDirectory()
        let parentDir: String
        let prefix: String
        if trimmed.hasSuffix("/") {
            parentDir = expanded
            prefix = ""
        } else {
            parentDir = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
        }
        let listDir = parentDir.isEmpty ? "/" : parentDir
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: listDir) else { return [] }
        let matches = entries.filter { name in
            guard !name.hasPrefix(".") || prefix.hasPrefix(".") else { return false }
            guard prefix.isEmpty || name.localizedCaseInsensitiveCompare(prefix) == .orderedSame || name.lowercased().hasPrefix(prefix.lowercased())
            else { return false }
            var isDirectory: ObjCBool = false
            let full = (listDir as NSString).appendingPathComponent(name)
            return fileManager.fileExists(atPath: full, isDirectory: &isDirectory) && isDirectory.boolValue
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return matches.prefix(limit).map { name in
            let full = (listDir as NSString).appendingPathComponent(name)
            if usesTilde, full == home { return "~" }
            if usesTilde, full.hasPrefix(home + "/") { return "~" + full.dropFirst(home.count) }
            return full
        }
    }

    private func handleCreateProjectRequest(_ request: SpacesDeviceProjectCreateRequest, context: RequestContext) throws -> SpacesDeviceAPIResponse {
        let projectDir = normalizedString(request.projectDir)
        let gitURL = normalizedString(request.gitURL)
        guard (projectDir == nil) != (gitURL == nil) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Provide exactly one project directory or Git URL.", errorCode: .invalidArgument)
        }

        let store = try context.store()
        let orchestrator = try context.orchestrator()
        let project: ProjectRecord
        if let projectDir {
            if let config = request.config {
                project = try orchestrator.addReviewedProject(dir: projectDir) { project in applyProjectConfig(config, to: &project) }
            } else {
                project = try orchestrator.addProject(dir: projectDir)
            }
        } else if let gitURL {
            // Clone the repository now (deferred from the add-project preview, which only fetched
            // spaces.yaml) and apply the client's reviewed config. addPreparedGitProject applies the
            // config unconditionally; addProject(gitURL:) would instead discard it in favor of the
            // repo's own spaces.yaml, dropping any edits the user made in the form.
            let prepared = try orchestrator.prepareGitProject(gitURL: gitURL, replaceExistingManagedDirectories: true)
            do {
                project = try orchestrator.addPreparedGitProject(prepared) { project in
                    if let config = request.config { applyProjectConfig(config, to: &project) }
                }
            } catch {
                try? orchestrator.discardPreparedGitProject(prepared)
                throw error
            }
        } else {
            return SpacesDeviceAPIResponse(ok: false, message: "Provide exactly one project directory or Git URL.", errorCode: .invalidArgument)
        }
        let defaultWorkspaceID = try store.workspaces(projectID: project.id).first(where: \.isDefault)?.id
        return try refreshedMutationResponse(
            context: context, message: "Created project '\(project.name)'.", projectID: project.id, workspaceID: defaultWorkspaceID)
    }

    /// Loads a git repository's `spaces.yaml` for the add-project preview by fetching only that single
    /// file (no clone), returning the detected config to populate the add form plus any managed
    /// directories a later Create would replace. The full clone is deferred to `createProject`.
    private func handleGitPreviewRequest(_ request: SpacesDeviceGitProjectPreviewRequest, context: RequestContext) throws -> SpacesDeviceAPIResponse {
        guard let gitURL = normalizedString(request.gitURL) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Git repository URL is required.", errorCode: .invalidArgument)
        }
        let preview = try context.orchestrator().previewGitProject(gitURL: gitURL)
        let candidates = preview.replacementCandidates.map { SpacesDeviceManagedDirectoryReplacementCandidate(kind: $0.kind.rawValue, path: $0.path) }
        return SpacesDeviceAPIResponse(
            ok: true, message: "Loaded git project preview.",
            result: .gitProjectPreview(
                SpacesDeviceGitProjectPreview(
                    config: SpacesDeviceOverviewBuilder.projectConfig(from: preview.project), replacementCandidates: candidates,
                    spacesYAMLFound: preview.spacesYAMLFound)))
    }

    private func handleDeleteProjectRequest(_ request: SpacesDeviceProjectReference, context: RequestContext) throws -> SpacesDeviceAPIResponse {
        let store = try context.store()
        let orchestrator = try context.orchestrator()
        guard let project = try store.project(id: request.projectID) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Project not found.", errorCode: .notFound)
        }
        // Every workspace of the project is torn down by this, so every one of them is reported as
        // deleting — a client watching any of them sees the same fact an archive publishes.
        //
        // Accepted risk: this snapshot is read before `removeProject` claims the project gate, so a
        // workspace created in the gap is deleted by the gated re-read inside `removeProject` without
        // ever being registered here. Registering the gated set instead would mean registering after
        // teardown work has begun, giving every overview built in that window an unreported teardown —
        // a worse trade than a race that needs a same-moment create-vs-delete of one project across
        // clients and costs only a row that stays ordinary until the next overview drops it.
        let workspaceIDs = try store.workspaces(projectID: project.id).map(\.id)
        try withTeardownRegistered(workspaceIDs: workspaceIDs) { try orchestrator.removeProject(id: project.id) }
        return try refreshedMutationResponse(context: context, message: "Deleted project '\(project.name)'.")
    }

    private func handleImportProjectRequest(_ request: SpacesDeviceProjectImportRequest, context: RequestContext) throws -> SpacesDeviceAPIResponse {
        _ = try context.orchestrator().importSpacesYAML(projectID: request.projectID, updateAllWorkspaces: request.updateAllWorkspaces)
        return try refreshedMutationResponse(context: context, message: "Imported spaces.yaml.", projectID: request.projectID)
    }

    private func handleExportProjectRequest(_ request: SpacesDeviceProjectReference, context: RequestContext) throws -> SpacesDeviceAPIResponse {
        let url = try context.orchestrator().exportSpacesYAML(projectID: request.projectID)
        return try refreshedMutationResponse(context: context, message: "Exported spaces.yaml to \(url.path).", projectID: request.projectID)
    }

    private func handleCreateWorkspaceRequest(_ request: SpacesDeviceWorkspaceCreateRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let projectID = request.projectID
        let store = try context.store()
        let orchestrator = try context.orchestrator()
        let project = try store.project(id: projectID)
        // Create the workspace record and worktree synchronously, but leave the setup script
        // deferred (status `.pending`). A long-running setup script (e.g. a full build) would
        // otherwise block this request well past the client's request timeout, leaving the New
        // Workspace form stuck on "Creating...". Running setup in the background lets the response
        // return immediately so the UI can navigate to the workspace and stream its setup log.
        let workspace = try orchestrator.createWorkspace(
            projectID: projectID, branch: normalizedString(request.branch), baseBranch: normalizedString(request.baseBranch),
            directoryName: normalizedString(request.directoryName), runSetupScript: false, allowRemoteBranchLookup: true,
            allowExistingBranchReuse: request.allowExistingBranchReuse)
        if let notes = normalizedOptionalString(request.notes) { try orchestrator.updateWorkspaceNotes(workspaceID: workspace.id, notes: notes) }
        runWorkspaceSetupInBackground(workspaceID: workspace.id)
        let message = "Created workspace '\(workspace.displayName)'\(project.map { " in \($0.name)" } ?? "")."
        return try refreshedMutationResponse(context: context, message: message, workspaceID: workspace.id)
    }

    /// Runs a newly created workspace's deferred setup script on a background queue.
    ///
    /// Mirrors `finishReservedWorkspaceTerminalLaunchInBackground`: a fresh store and orchestrator
    /// are created inside the closure so only the `Sendable` workspace ID is captured. The setup
    /// state machine (`.pending` -> `.running` -> `.succeeded`/`.failed`) and the setup log are
    /// owned by `runWorkspaceSetup`, so progress and failures remain observable through the normal
    /// workspace setup detail UI without this request blocking on completion.
    private func runWorkspaceSetupInBackground(workspaceID: String) {
        let launcher = builtInTerminalSessionLauncher
        let terminator = builtInTerminalSessionTerminator
        let traceEnabled = traceEnabled
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                let orchestrator = WorkspaceOrchestrator(
                    store: store, builtInTerminalWindowOpener: { _, _, _ in }, deliversTerminalWindowOpens: false,
                    builtInTerminalSessionTerminator: terminator, builtInTerminalSessionLauncher: launcher)
                try orchestrator.runWorkspaceSetup(workspaceID: workspaceID)
            } catch {
                guard traceEnabled else { return }
                let message = String(describing: error).replacingOccurrences(of: "\n", with: "\\n")
                FileHandle.standardOutput.write(
                    Data("spaces-device-api-trace workspace_background_setup_error workspace=\(workspaceID) error=\(message)\n".utf8))
            }
        }
    }

    private func handleLaunchWorkspaceRequest(_ request: SpacesDeviceWorkspaceLifecycleRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        try context.orchestrator().launchWorkspace(workspaceID: request.workspaceID)
        return try refreshedMutationResponse(context: context, message: "Launched workspace.", workspaceID: request.workspaceID)
    }

    private func handleStopWorkspaceRequest(_ request: SpacesDeviceWorkspaceLifecycleRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        _ = try context.orchestrator().stopWorkspace(workspaceID: request.workspaceID)
        return try refreshedMutationResponse(context: context, message: "Stopped workspace.", workspaceID: request.workspaceID)
    }

    private func handleRestartWorkspaceRequest(_ request: SpacesDeviceWorkspaceLifecycleRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        try context.orchestrator().upWorkspace(workspaceID: request.workspaceID, restartIfRunning: true, background: true)
        return try refreshedMutationResponse(context: context, message: "Restarted workspace.", workspaceID: request.workspaceID)
    }

    private func handleArchiveWorkspaceRequest(_ request: SpacesDeviceWorkspaceArchiveRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        // The outcome carries what happened to each branch the request asked to delete, which the user is
        // owed whether it succeeded, found nothing, skipped a protected branch, or failed.
        //
        // Registered as torn down for the whole archive: a client whose delete response was lost probes the
        // overview to find out what happened, and while this runs it must read "still being deleted" rather
        // than mistaking a slow stop script for a failed delete.
        let outcome = try withTeardownRegistered(workspaceIDs: [request.workspaceID]) {
            try context.orchestrator().archiveWorkspace(
                workspaceID: request.workspaceID, deleteLocalBranch: request.deleteLocalBranch, deleteRemoteBranch: request.deleteRemoteBranch)
        }
        return try refreshedMutationResponse(
            context: context, message: "Deleted workspace.", workspaceID: request.workspaceID, notice: outcome.notice)
    }

    private func handleRunWorkspaceSetupRequest(_ request: SpacesDeviceWorkspaceReference, context: RequestContext) throws -> SpacesDeviceAPIResponse
    {
        try context.orchestrator().runWorkspaceSetup(workspaceID: request.workspaceID)
        return try refreshedMutationResponse(context: context, message: "Ran workspace setup.", workspaceID: request.workspaceID)
    }

    /// Read/write cap for one file in `workspaceFileRead`/`workspaceFileWrite`, matching the existing
    /// `terminalPasteImageMaxBytes` precedent for a single-response (non-chunked) payload cap.
    static let workspaceFileMaxBytes = 10 * 1024 * 1024

    /// Reads `path`'s content for `workspaceFileRead`/`workspaceFileWrite`'s CAS, in place of
    /// `FileManager.contents(atPath:)`. Callers must reject a non-regular existing path (via
    /// `attributes[.type]` from the same `attributesOfItem` stat used for the size pre-check) before calling
    /// this: `attributesOfItem` never blocks, even against a FIFO or socket, but opening one of those for
    /// read does — a FIFO blocks until a writer appears, with no timeout, wedging this workspace's serial
    /// queue forever. That type guard is what keeps the blocking open from happening at all; this function
    /// only ever runs against a path already confirmed regular. The read is still bounded to `cap + 1` bytes
    /// rather than trusting the stat's size: the stat and this read are not atomic, so a file replaced or
    /// grown in between would otherwise let an unbounded read-to-EOF materialize an arbitrarily large
    /// payload despite the size guard having passed. Returns `nil` only when the path could not be opened, or
    /// the read itself threw (e.g. permissions) — never for an existing empty file: `FileHandle.read(upToCount:)`
    /// returning `nil` at EOF is a *successful* read of zero bytes, which this maps to empty `Data`, matching
    /// what `FileManager.contents(atPath:)` returns for an empty file. Callers keep their existing
    /// not-found/unreadable distinctions unchanged.
    private static func boundedReadWorkspaceFile(atPath path: String, cap: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do { return try handle.read(upToCount: cap + 1) ?? Data() } catch { return nil }
    }

    /// Resolves `workspaceID` to its checkout directory, or throws the same `NSError(domain:
    /// "SpacesDeviceAPIServer", code: 404)` the rest of this file uses for a not-found target (mapped to
    /// `.notFound` by `errorCode(for:)`).
    private func resolveWorkspaceDirectory(workspaceID: String, context: RequestContext) throws -> String {
        guard let workspace = try context.store().workspace(id: workspaceID) else { throw Self.workspaceNotFoundError(workspaceID: workspaceID) }
        return workspace.dir
    }

    /// Reads a bounded regular checkout file. The revision-read endpoint shares this exact path so
    /// its returned CAS baseline has the same containment, type, and cap guarantees as a normal file read.
    private func workspaceFileReadResponse(
        relativePath: String, workspaceDir: String, comparisonBaseRevision: String? = nil, oldPath: String? = nil,
        requiresDirectPath: Bool = false
    ) -> SpacesDeviceAPIResponse {
        let resolvedPath: String
        do {
            resolvedPath = try (
                requiresDirectPath
                    ? SpacesDeviceWorkspacePathResolver.resolveDirectPath(relativePath: relativePath, workspaceDir: workspaceDir)
                    : SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: relativePath, workspaceDir: workspaceDir))
        } catch SpacesDeviceWorkspacePathResolver.PathError.containsSymbolicLink {
            return SpacesDeviceAPIResponse(
                ok: false, message: "Inline diff editing cannot follow symbolic links.", errorCode: .invalidArgument)
        } catch { return SpacesDeviceAPIResponse(ok: false, message: "Path escapes the workspace directory.", errorCode: .invalidArgument) }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath), let size = attributes[.size] as? Int else {
            return SpacesDeviceAPIResponse(ok: false, message: "File '\(relativePath)' was not found.", errorCode: .notFound)
        }
        // `attributesOfItem` (the stat above) never blocks, even against a FIFO or socket, but opening one of
        // those for read does — a FIFO in particular blocks until a writer appears, with no timeout, wedging
        // this workspace's serial queue forever. Refusing a non-regular path here means the blocking open in
        // `boundedReadWorkspaceFile` below never happens; this guard is the fix, not a timeout around the
        // read. Stat-then-read is also an inherent TOCTOU pair (the file could change between the two), which
        // is why the read below is bounded to `cap + 1` bytes rather than trusting this stat's size — see
        // `boundedReadWorkspaceFile`'s doc comment.
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return SpacesDeviceAPIResponse(ok: false, message: "Path is not a regular file.", errorCode: .invalidArgument)
        }
        guard size <= Self.workspaceFileMaxBytes else {
            return SpacesDeviceAPIResponse(ok: false, message: "File exceeds the 10 MiB read limit.", errorCode: .payloadTooLarge)
        }
        guard let data = Self.boundedReadWorkspaceFile(atPath: resolvedPath, cap: Self.workspaceFileMaxBytes) else {
            // `attributesOfItem` above already succeeded (a plain `stat`, which only needs directory
            // search/execute permission), so the file is confirmed to exist; a nil bounded read here means it
            // could not be opened/read (e.g. permissions), never that it is missing. Reporting `.notFound`
            // would be a silent conflation an automated retry could misinterpret as "safe to create".
            return SpacesDeviceAPIResponse(
                ok: false, message: "File '\(relativePath)' exists but could not be read.", errorCode: .internalError)
        }
        guard data.count <= Self.workspaceFileMaxBytes else {
            // The stat-based check above is the cheap fast path; this is the guard that cannot be raced — the
            // file grew between the stat and this read.
            return SpacesDeviceAPIResponse(ok: false, message: "File exceeds the 10 MiB read limit.", errorCode: .payloadTooLarge)
        }
        let comparisonOldData: Data?
        if let comparisonBaseRevision {
            guard Self.isFullGitRevision(comparisonBaseRevision), oldPath.map(Self.isSafeGitRelativePath) ?? true else {
                return SpacesDeviceAPIResponse(
                    ok: false, message: "Comparison revision and path must be immutable and workspace-relative.", errorCode: .invalidArgument)
            }
            do {
                try SpacesDeviceWorkspaceDiffEngine.assertIsGitRepository(workspaceDir: workspaceDir, gitClient: workspaceGitClient)
                let comparisonPath = oldPath ?? relativePath
                switch try gitTreePath(at: comparisonBaseRevision, relativePath: comparisonPath, workspaceDir: workspaceDir) {
                case .missing:
                    comparisonOldData = nil
                case .nonRegular:
                    return SpacesDeviceAPIResponse(
                        ok: false, message: "Comparison file is not a regular file.", errorCode: .invalidArgument)
                case .regularBlob:
                    comparisonOldData = try workspaceGitClient.runGitAndCaptureData(
                        ["-C", workspaceDir, "cat-file", "--filters", "\(comparisonBaseRevision):./\(comparisonPath)"], timeout: 10,
                        maxOutputBytes: Self.workspaceFileMaxBytes)
                }
            } catch SpacesRuntimeError.outputExceededCap {
                return SpacesDeviceAPIResponse(ok: false, message: "File exceeds the 10 MiB read limit.", errorCode: .payloadTooLarge)
            } catch {
                return SpacesDeviceAPIResponse(ok: false, message: "Could not read the comparison file.", errorCode: .internalError)
            }
        } else {
            comparisonOldData = nil
        }
        return SpacesDeviceAPIResponse(
            ok: true, message: "Read workspace file.",
            result: .workspaceFileRead(
                .init(
                    base64Data: data.base64EncodedString(), sha256: SpacesDeviceWorkspaceGitHashing.sha256Hex(data), size: data.count,
                    isBinaryGuess: SpacesDeviceWorkspaceBinaryGuess.isLikelyBinary(data),
                    comparisonOldBase64Data: comparisonBaseRevision == nil ? nil : comparisonOldData?.base64EncodedString())))
    }

    private func handleWorkspaceFileReadRequest(_ request: SpacesDeviceWorkspaceFileReadRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceDir = try resolveWorkspaceDirectory(workspaceID: request.workspaceID, context: context)
        return workspaceFileReadResponse(
            relativePath: request.relativePath, workspaceDir: workspaceDir,
            comparisonBaseRevision: request.comparisonBaseRevision, oldPath: request.oldPath, requiresDirectPath: request.requiresDirectPath)
    }

    /// Reads one blob from an immutable commit, never from the working tree. The path is validated as a
    /// lexical workspace-relative Git path rather than resolved on disk: a last-commit file may have been
    /// renamed or deleted since that commit, so filesystem/symlink resolution would reject a valid object.
    private func handleWorkspaceRevisionFileReadRequest(_ request: SpacesDeviceWorkspaceRevisionFileReadRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        guard Self.isFullGitRevision(request.revision), Self.isSafeGitRelativePath(request.relativePath),
            request.oldPath.map(Self.isSafeGitRelativePath) ?? true
        else {
            return SpacesDeviceAPIResponse(
                ok: false, message: "Revision must be a full object id and path must be workspace-relative.", errorCode: .invalidArgument)
        }
        let workspaceDir = try resolveWorkspaceDirectory(workspaceID: request.workspaceID, context: context)
        try SpacesDeviceWorkspaceDiffEngine.assertIsGitRepository(workspaceDir: workspaceDir, gitClient: workspaceGitClient)

        // A full-hex revision cannot be parsed as an option. The path is one object-expression argument
        // following the revision and `:./`, never a separate pathspec or command-line option.
        let resolved = try workspaceGitClient.runGitAndCapture(
            ["-C", workspaceDir, "rev-parse", "--verify", "--quiet", "\(request.revision)^{commit}"], timeout: 2, allowedExitCodes: [0, 1])
        guard !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SpacesDeviceAPIResponse(ok: false, message: "Revision was not found in this workspace.", errorCode: .invalidArgument)
        }
        let targetHash: String
        let targetIsExecutable: Bool
        switch try gitTreePath(at: request.revision, relativePath: request.relativePath, workspaceDir: workspaceDir) {
        case .missing:
            return SpacesDeviceAPIResponse(ok: false, message: "File was not found at this revision.", errorCode: .notFound)
        case .nonRegular:
            return SpacesDeviceAPIResponse(
                ok: false, message: "File at this revision is not a regular file.", errorCode: .invalidArgument)
        case .regularBlob(let objectID, let mode):
            targetHash = objectID
            targetIsExecutable = mode == "100755"
        }
        // Last Commit can edit only the tracked path itself. The ordinary workspace reader follows
        // contained links by design, but accepting one here would let a reviewed regular file save
        // through a different leaf or directory. Resolving the workspace root itself remains valid.
        guard !lastCommitWorktreePathTraversesSymbolicLink(relativePath: request.relativePath, workspaceDir: workspaceDir) else {
            return SpacesDeviceAPIResponse(
                ok: false, message: "Last Commit editing requires a direct workspace file path.", errorCode: .invalidArgument)
        }
        // Read the editable worktree bytes before the equivalence check below. If checkout churns
        // between this read and `git diff`, the check reports false and the browser rejects this
        // baseline; if it churns after the check, the returned SHA remains the CAS write token.
        // The revision target is intentionally only existence/type checked above: it is never
        // transferred or size-capped, unlike this live baseline and the comparison side below.
        let worktreeRead = workspaceFileReadResponse(relativePath: request.relativePath, workspaceDir: workspaceDir)
        guard worktreeRead.ok, let worktreeFile = worktreeRead.workspaceFileRead else { return worktreeRead }
        // Hash the bytes just read through Git's clean-filter path, rather than `git diff`'s
        // index-aware working-tree scan: assume-unchanged/skip-worktree must not hide a real live
        // divergence. The temporary input is exactly the response's CAS baseline, so the equality
        // check cannot verify different bytes from those the editor would later save. Git tracks the
        // executable bit too, so exact equivalence needs both the filtered blob and direct leaf mode.
        let worktreeIsExecutable = lastCommitDirectWorktreeExecutable(
            relativePath: request.relativePath, workspaceDir: workspaceDir)
        let filteredWorktreeHash: String?
        if worktreeIsExecutable == targetIsExecutable {
            let baselineData = Data(base64Encoded: worktreeFile.base64Data)!
            filteredWorktreeHash = try gitFilteredHash(
                data: baselineData, relativePath: request.relativePath, workspaceDir: workspaceDir)
        } else {
            filteredWorktreeHash = nil
        }
        let parent = try workspaceGitClient.runGitAndCapture(
            ["-C", workspaceDir, "rev-parse", "--verify", "--quiet", "\(request.revision)^"], timeout: 2, allowedExitCodes: [0, 1])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let comparisonOldData: Data?
        if parent.isEmpty {
            comparisonOldData = nil
        } else {
            let oldPath = request.oldPath ?? request.relativePath
            do {
                switch try gitTreePath(at: parent, relativePath: oldPath, workspaceDir: workspaceDir) {
                case .missing:
                    comparisonOldData = nil
                case .nonRegular:
                    return SpacesDeviceAPIResponse(
                        ok: false, message: "Comparison file is not a regular file.", errorCode: .invalidArgument)
                case .regularBlob:
                    comparisonOldData = try workspaceGitClient.runGitAndCaptureData(
                        ["-C", workspaceDir, "cat-file", "--filters", "\(parent):./\(oldPath)"], timeout: 10,
                        maxOutputBytes: Self.workspaceFileMaxBytes)
                }
            } catch SpacesRuntimeError.outputExceededCap {
                return SpacesDeviceAPIResponse(ok: false, message: "File exceeds the 10 MiB read limit.", errorCode: .payloadTooLarge)
            }
        }
        return SpacesDeviceAPIResponse(
            ok: true, message: "Read workspace revision file.",
            result: .workspaceRevisionFileRead(
                .init(
                    worktreeFile: worktreeFile,
                    isWorktreeEquivalentToRevision: filteredWorktreeHash == targetHash,
                    comparisonOldBase64Data: comparisonOldData?.base64EncodedString())))
    }

    /// Runs Git's configured clean filters over already-bounded checkout bytes. `hash-object --path`
    /// chooses attributes as if the data belonged at `relativePath`, while the private temporary file
    /// prevents a second read of a concurrently changing worktree path from weakening the CAS guard.
    private func gitFilteredHash(data: Data, relativePath: String, workspaceDir: String) throws -> String {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-git-filter-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: input.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "SpacesDeviceAPIServer", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not prepare Git filter input."])
        }
        defer { try? FileManager.default.removeItem(at: input) }
        return try workspaceGitClient.runGitAndCapture(
            ["-C", workspaceDir, "hash-object", "--path=\(relativePath)", input.path], timeout: 10)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum GitTreePath {
        case missing
        case regularBlob(objectID: String, mode: String)
        case nonRegular
    }

    /// `ls-tree -z` is the structured authority for a revision path. It keeps normal absence
    /// separate from execution failures and locale-dependent diagnostics before a filtered blob
    /// read, while `:(literal)` preserves filenames such as `app/[slug].tsx` in a subtree workspace.
    private func gitTreePath(at revision: String, relativePath: String, workspaceDir: String) throws -> GitTreePath {
        let output = try workspaceGitClient.runGitAndCapture(
            ["-C", workspaceDir, "ls-tree", "-z", revision, "--", ":(literal)\(relativePath)"], timeout: 10)
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true)
        guard entries.count <= 1 else {
            throw NSError(domain: "SpacesDeviceAPIServer", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Git tree lookup returned multiple entries for one literal path.",
            ])
        }
        guard let entry = entries.first else { return .missing }
        guard let tab = entry.firstIndex(of: "\t") else {
            throw NSError(domain: "SpacesDeviceAPIServer", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Git tree lookup returned malformed output.",
            ])
        }
        let fields = entry[..<tab].split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3 else {
            throw NSError(domain: "SpacesDeviceAPIServer", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Git tree lookup returned malformed metadata.",
            ])
        }
        guard fields[1] == "blob" else { return .nonRegular }
        switch fields[0] {
        case "100644", "100755": return .regularBlob(objectID: String(fields[2]), mode: String(fields[0]))
        default: return .nonRegular
        }
    }

    /// Walks from the resolved workspace root, deliberately excluding a symlink that names the
    /// workspace itself but rejecting every user-controlled component below it. This Last Commit-only
    /// guard keeps its returned CAS path identical to the regular path Git's tree entry describes.
    private func lastCommitWorktreePathTraversesSymbolicLink(relativePath: String, workspaceDir: String) -> Bool {
        let root = URL(fileURLWithPath: workspaceDir, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        var candidate = root
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            candidate.appendPathComponent(String(component), isDirectory: false)
            var status = stat()
            // Let the shared worktree reader give missing/permission paths their established typed
            // result. A successful lstat here is enough to reject only an observed redirect.
            guard lstat(candidate.path, &status) == 0 else { return false }
            if (status.st_mode & S_IFMT) == S_IFLNK { return true }
        }
        return false
    }

    /// Returns the executable bit only for a direct regular leaf. A churned/missing/non-regular
    /// path cannot prove exact Last Commit equivalence and therefore returns nil.
    private func lastCommitDirectWorktreeExecutable(relativePath: String, workspaceDir: String) -> Bool? {
        let root = URL(fileURLWithPath: workspaceDir, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let path = relativePath.split(separator: "/", omittingEmptySubsequences: true).reduce(root) {
            $0.appendingPathComponent(String($1), isDirectory: false)
        }
        var status = stat()
        guard lstat(path.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
        return (status.st_mode & S_IXUSR) != 0
    }

    private static func isFullGitRevision(_ revision: String) -> Bool {
        guard revision.utf8.count == 40 || revision.utf8.count == 64 else { return false }
        return revision.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }
    }


    private static func isSafeGitRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    /// Lists every path in a workspace's checkout for the Editor pane's file tree/quick-open; see
    /// `SpacesDeviceWorkspaceFileListEngine.listFiles`. Read-only, so unlike the CAS file read/write handlers
    /// above there is no path-escape or size guard to apply, and unlike `handleWorkspaceDiffManifestRequest` there is
    /// no `assertIsGitRepository` gate here either: this endpoint deliberately serves both git and non-git
    /// workspaces, because a non-git workspace's Editor (docs/spec.md's non-git project rows still offer Open
    /// in Editor) has no other way to open a file — the tree and ⌘P quick-open ARE the file picker for it.
    /// `listFiles` itself picks the git-vs-filesystem listing strategy per call.
    private func handleWorkspaceFileListRequest(_ request: SpacesDeviceWorkspaceFileListRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceDir = try resolveWorkspaceDirectory(workspaceID: request.workspaceID, context: context)
        let result = try SpacesDeviceWorkspaceFileListEngine.listFiles(workspaceDir: workspaceDir, gitClient: workspaceGitClient)
        return SpacesDeviceAPIResponse(ok: true, message: "Listed workspace files.", result: .workspaceFileList(result))
    }

    /// Lists the branches and recent commits the Compare dialog's ref search offers; see
    /// `SpacesDeviceWorkspaceRefListEngine.listRefs`. Read-only, and like `handleWorkspaceFileListRequest`
    /// (its closest sibling) has no `assertIsGitRepository` gate of its own: a non-git workspace simply has
    /// nothing to list, which the engine itself already reports as empty, untruncated lists rather than an
    /// error.
    private func handleWorkspaceRefListRequest(_ request: SpacesDeviceWorkspaceRefListRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let deadlineStart = Date()
        guard let workspace = try context.store().workspace(id: request.workspaceID) else {
            throw Self.workspaceNotFoundError(workspaceID: request.workspaceID)
        }
        let result = try SpacesDeviceWorkspaceRefListEngine.listRefs(
            workspaceDir: workspace.dir, baseBranch: workspace.baseBranch, gitClient: workspaceGitClient, deadlineStart: deadlineStart)
        return SpacesDeviceAPIResponse(ok: true, message: "Listed workspace refs.", result: .workspaceRefList(result))
    }

    /// Compare-and-swap write. `expectedSHA256` is compared against the current disk content's hash
    /// (`nil` on both sides only when the file does not exist yet); a mismatch is reported as a typed
    /// `SpacesDeviceWorkspaceFileWriteResult` conflict (`ok: true`, `didWrite: false`), not a transport
    /// error, per the spec: the client runs its own three-way merge and retries rather than treating this
    /// as a failure. round-13 Fix 4: a mismatch whose current bytes already equal the requested `newData` is
    /// not a conflict — it is a retry of a write that already landed — and is reported as an idempotent
    /// success (`didWrite: true`) instead; see the guard below.
    private func handleWorkspaceFileWriteRequest(_ request: SpacesDeviceWorkspaceFileWriteRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceDir = try resolveWorkspaceDirectory(workspaceID: request.workspaceID, context: context)
        let resolvedPath: String
        do {
            resolvedPath = try (
                request.requiresDirectPath
                    ? SpacesDeviceWorkspacePathResolver.resolveDirectPath(relativePath: request.relativePath, workspaceDir: workspaceDir)
                    : SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: request.relativePath, workspaceDir: workspaceDir))
        } catch SpacesDeviceWorkspacePathResolver.PathError.containsSymbolicLink {
            return SpacesDeviceAPIResponse(
                ok: false, message: "Inline diff editing cannot follow symbolic links.", errorCode: .invalidArgument)
        } catch { return SpacesDeviceAPIResponse(ok: false, message: "Path escapes the workspace directory.", errorCode: .invalidArgument) }
        guard let newData = Data(base64Encoded: request.base64Data) else {
            return SpacesDeviceAPIResponse(ok: false, message: "File content is not valid base64.", errorCode: .invalidArgument)
        }
        guard newData.count <= Self.workspaceFileMaxBytes else {
            return SpacesDeviceAPIResponse(ok: false, message: "File exceeds the 10 MiB write limit.", errorCode: .payloadTooLarge)
        }
        // Mirror the read handler's size guard before touching the current on-disk content: an oversized
        // file makes the whole save flow unusable regardless of what the client sent (the read path refuses
        // it too), so this is a hard error, not a CAS conflict result. Checking size first also avoids
        // hashing a huge file just to compare it against `expectedSHA256`.
        let existingAttributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath)
        if let existingAttributes, let size = existingAttributes[.size] as? Int, size > Self.workspaceFileMaxBytes {
            return SpacesDeviceAPIResponse(
                ok: false, message: "File on disk exceeds the 10 MiB limit and cannot be read for a compare-and-swap write.",
                errorCode: .payloadTooLarge)
        }
        // See `handleWorkspaceFileReadRequest`'s guard for the FIFO-wedge/TOCTOU rationale — the same
        // `attributesOfItem`-never-blocks-but-open-does hazard applies to this handler's CAS read of the
        // current content below. A nonexistent path (`existingAttributes == nil`) keeps its current create
        // semantics; only an EXISTING non-regular path (a directory, socket, FIFO) is refused here, since a
        // CAS write over one is never meaningful.
        if let existingAttributes, existingAttributes[.type] as? FileAttributeType != .typeRegular {
            return SpacesDeviceAPIResponse(ok: false, message: "Path is not a regular file.", errorCode: .invalidArgument)
        }

        let currentData = Self.boundedReadWorkspaceFile(atPath: resolvedPath, cap: Self.workspaceFileMaxBytes)
        if currentData == nil, existingAttributes != nil {
            // A bounded read returning nil despite the path existing (per the stat above) means it could not
            // be opened/read (e.g. permissions). Left unguarded, an unreadable existing file would present as
            // `expectedSHA256 == nil` (create), let a create-write pass the CAS guard below, and silently
            // overwrite content nobody could compare against — no compare-and-swap decision is actually
            // possible here, so this must be a hard error rather than either CAS branch.
            return SpacesDeviceAPIResponse(
                ok: false, message: "File '\(request.relativePath)' exists but could not be read for a compare-and-swap write.",
                errorCode: .internalError)
        }
        if let currentData, currentData.count > Self.workspaceFileMaxBytes {
            // The stat-based check above is the cheap fast path; this is the guard that cannot be raced — the
            // file grew between the stat and this read.
            return SpacesDeviceAPIResponse(
                ok: false, message: "File on disk exceeds the 10 MiB limit and cannot be read for a compare-and-swap write.",
                errorCode: .payloadTooLarge)
        }
        let currentSHA256 = currentData.map { SpacesDeviceWorkspaceGitHashing.sha256Hex($0) }
        // This compare-and-swap is advisory, not a lock: nothing stops an external writer (an editor, a
        // coding agent, `git checkout`) from touching `resolvedPath` in the window between the hash above and
        // `atomicallyWriteWorkspaceFile`'s rename below, since none of those participate in any lock this
        // handler could take. The coarse case this guards — the file changed since the client last read it,
        // e.g. a save from a stale tab — is caught here every time; only the sub-millisecond hash-to-rename
        // window against a concurrent external writer is not, and closing that would require every external
        // writer to honor a lock this process cannot impose. Accepted: a write lost to that window is
        // recoverable via git, and the window this narrow is unlikely to matter in practice.
        guard currentSHA256 == request.expectedSHA256 else {
            // round-13 Fix 4: a stale `expectedSHA256` is only a genuine conflict when the bytes actually
            // differ. A retry of an already-landed write — its original response lost to a transport drop or
            // the client hibernating mid-round-trip — replays the same `newData` against a now-stale
            // `expectedSHA256`, since the client never learned the first write succeeded. Reporting that as
            // `.conflict` would be a false positive: nothing raced, the content on disk already matches what
            // the caller is asking to write. Treat identical bytes as an idempotent success instead, and only
            // fall through to the conflict report below for content that genuinely differs.
            if let currentData, currentData == newData {
                return SpacesDeviceAPIResponse(
                    ok: true, message: "Workspace file already matches the requested content.",
                    result: .workspaceFileWrite(.init(didWrite: true, sha256: currentSHA256)))
            }
            return SpacesDeviceAPIResponse(
                ok: true, message: "Workspace file changed since it was last read.",
                result: .workspaceFileWrite(
                    .init(didWrite: false, currentBase64Data: currentData?.base64EncodedString(), currentSHA256: currentSHA256)))
        }

        do { try Self.atomicallyWriteWorkspaceFile(newData, to: resolvedPath) } catch {
            return SpacesDeviceAPIResponse(
                ok: false, message: "Failed to write workspace file: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))",
                errorCode: .internalError)
        }
        return SpacesDeviceAPIResponse(
            ok: true, message: "Wrote workspace file.",
            result: .workspaceFileWrite(.init(didWrite: true, sha256: SpacesDeviceWorkspaceGitHashing.sha256Hex(newData))))
    }

    /// Writes `data` to `path` via `Data.write(options: .atomic)`, which writes an auxiliary file in the
    /// same directory and renames it into place — the temp-file-plus-rename atomicity the spec asks for,
    /// without hand-rolling it. Creates any missing intermediate directories first, since `expectedSHA256
    /// == nil` (create) is the one case `path`'s parent might not exist yet.
    ///
    /// This runs on the request's per-workspace `workspaceGitQueue(for:)`, which is not gated against
    /// `workspaceTeardownQueue` (archive/delete). A write racing a workspace's archive or its project's
    /// deletion can therefore recreate part of a just-removed worktree directory via `createDirectory`
    /// above, or report a successful write for content that is deleted moments later. Accepted rather than
    /// gated: deleting a workspace closes its panes first, so hitting this requires a save landing in the
    /// same instant as a delete, and the recreated directory is inert (nothing paired with it) once the
    /// deletion has actually completed.
    ///
    /// The rename-into-place this performs replaces the target file's inode, which drops any custom
    /// extended attributes an existing file carried (Finder tags, quarantine flags, etc.) — empirically
    /// confirmed on macOS. Accepted, with no preservation code: every file here lives in a git worktree,
    /// and git neither tracks nor restores xattrs on checkout or branch switch, so any xattr on one of
    /// these files is already ephemeral regardless of this endpoint — preserving it would mean
    /// platform-divergent copy code in service of metadata with no durability in this domain. POSIX
    /// permissions are a different matter: git does track the exec bit, so this captures an existing
    /// file's mode before the write and restores it after. That restore is required on Linux: Foundation's
    /// atomic write preserves the replaced file's mode on macOS, but swift-corelibs-foundation's atomic
    /// write is a separate implementation that does not — it recreates the file at a default mode instead
    /// (confirmed empirically; see `WorkspaceFileWriteModePreservationTests`, which runs on both platforms).
    /// A newly created file has no prior mode to restore, so it keeps whatever the write gives it.
    ///
    /// `internal` rather than `private`: the existing `workspaceFileWrite` coverage in
    /// `WorkspaceGitServerTests` drives this through the real TLS request/response path, but that harness
    /// needs `Network`/`Security`, which the Linux daemon build does not have — so the mode-preservation
    /// regression test calls this directly instead, the only way to exercise the real write path (not a
    /// reimplementation of it) on both platforms.
    static func atomicallyWriteWorkspaceFile(_ data: Data, to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let existingPermissions = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        if let existingPermissions { try FileManager.default.setAttributes([.posixPermissions: existingPermissions], ofItemAtPath: path) }
    }

    private func handleWorkspaceDiffManifestChunkRequest(_ request: SpacesDeviceWorkspaceDiffManifestChunkRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        guard request.fileIndex >= 0 else {
            return SpacesDeviceAPIResponse(ok: false, message: "fileIndex must not be negative.", errorCode: .invalidArgument)
        }
        guard !(request.lastCommit && SpacesDeviceWorkspaceDiffEngine.normalizedRefName(request.refName) != nil) else {
            return SpacesDeviceAPIResponse(ok: false, message: "lastCommit and refName are mutually exclusive.", errorCode: .invalidArgument)
        }
        let scope = WorkspaceDiffScope(workspaceID: request.workspaceID, refName: request.refName, lastCommit: request.lastCommit)
        let manifestID: String
        let manifest: WorkspaceDiffTransferStore.ManifestSession
        if let requestedManifestID = request.manifestID, !requestedManifestID.isEmpty {
            manifestID = requestedManifestID
            switch workspaceDiffTransfers.lookupManifest(manifestID: manifestID, scope: scope) {
            case .found(let session): manifest = session
            case .missing:
                return SpacesDeviceAPIResponse(ok: false, message: "Workspace diff manifest expired or was released.", errorCode: .notFound)
            case .mismatched:
                return SpacesDeviceAPIResponse(
                    ok: false, message: "Workspace diff manifest does not match this workspace or scope.", errorCode: .invalidArgument)
            }
        } else {
            guard request.fileIndex == 0 else {
                return SpacesDeviceAPIResponse(
                    ok: false, message: "manifestID is required after the initial metadata chunk.", errorCode: .invalidArgument)
            }
            let deadlineStart = Date()
            let workspaceDir = try resolveWorkspaceDirectory(workspaceID: request.workspaceID, context: context)
            try SpacesDeviceWorkspaceDiffEngine.assertIsGitRepository(workspaceDir: workspaceDir, gitClient: workspaceGitClient)
            if !scope.lastCommit, let refName = scope.refName {
                try SpacesDeviceWorkspaceDiffEngine.assertRefIsResolvable(
                    workspaceDir: workspaceDir, refName: refName, gitClient: workspaceGitClient, deadlineStart: deadlineStart)
            }
            let snapshot = try SpacesDeviceWorkspaceDiffEngine.buildDiffPlanSnapshot(
                workspaceDir: workspaceDir, refName: scope.refName, lastCommit: scope.lastCommit, gitClient: workspaceGitClient,
                deadlineStart: deadlineStart)
            let createdManifest = workspaceDiffTransfers.createManifest(scope: scope, workspaceDir: workspaceDir, snapshot: snapshot)
            manifestID = createdManifest.manifestID
            let session = createdManifest.session
            // The store may evict this manifest as another workspace request creates a generation before
            // the response is encoded. Use the atomically returned session rather than looking it up again;
            // the session is still valid for this response and retains the store's TTL/capacity decision.
            manifest = session
        }
        return try workspaceDiffManifestChunkResponse(manifestID: manifestID, snapshot: manifest.snapshot, fileIndex: request.fileIndex)
    }

    /// Includes the Device API envelope in the cap, not just the metadata array. Individual file metadata
    /// is encoded once to account for its exact JSON escaping; the empty-envelope baseline with `Int.max`
    /// reserves the largest possible cursor encoding, so this linear pass never underestimates response size.
    private static let workspaceDiffManifestChunkByteCap = 4 * 1024 * 1024

    func workspaceDiffManifestChunkResponse(manifestID: String, snapshot: SpacesDeviceWorkspaceDiffEngine.DiffPlanSnapshot, fileIndex: Int) throws
        -> SpacesDeviceAPIResponse
    {
        guard fileIndex <= snapshot.plans.count else {
            return SpacesDeviceAPIResponse(ok: false, message: "fileIndex is outside this workspace diff manifest.", errorCode: .invalidArgument)
        }
        let empty = SpacesDeviceAPIResponse(
            ok: true, message: "Loaded workspace diff manifest metadata chunk.",
            result: .workspaceDiffManifestChunk(
                .init(manifestID: manifestID, scopeSignature: snapshot.scopeSignature, files: [], nextFileIndex: Int.max)))
        // The wire is line-framed, so include its trailing newline in the public 4 MiB bound too.
        var encodedByteCount = try SpacesDeviceAPICodec.encodeResponseLine(empty).count
        var chunk: [SpacesDeviceWorkspaceDiffManifestFile] = []
        let metadataEncoder = JSONEncoder()
        var nextIndex = fileIndex
        while nextIndex < snapshot.plans.count {
            let plan = snapshot.plans[nextIndex]
            let file = SpacesDeviceWorkspaceDiffManifestFile(
                path: plan.path, oldPath: plan.oldPath, status: plan.status, comparisonBaseRevision: plan.comparisonBaseRevision)
            let encodedFileByteCount = try metadataEncoder.encode(file).count
            let delimiterByteCount = chunk.isEmpty ? 0 : 1
            guard encodedByteCount + delimiterByteCount + encodedFileByteCount <= Self.workspaceDiffManifestChunkByteCap else { break }
            encodedByteCount += delimiterByteCount + encodedFileByteCount
            chunk.append(file)
            nextIndex += 1
        }
        guard !chunk.isEmpty || fileIndex == snapshot.plans.count else {
            return SpacesDeviceAPIResponse(
                ok: false, message: "One workspace diff manifest file identity exceeds the metadata response limit.", errorCode: .payloadTooLarge)
        }
        let response = SpacesDeviceAPIResponse(
            ok: true, message: "Loaded workspace diff manifest metadata chunk.",
            result: .workspaceDiffManifestChunk(
                .init(
                    manifestID: manifestID, scopeSignature: snapshot.scopeSignature, files: chunk,
                    nextFileIndex: nextIndex < snapshot.plans.count ? nextIndex : nil)))
        let encodedResponse = try SpacesDeviceAPICodec.encodeResponseLine(response)
        precondition(
            encodedResponse.count <= Self.workspaceDiffManifestChunkByteCap, "Workspace diff manifest metadata response exceeded its byte cap.")
        return response
    }

    private func handleWorkspaceDiffManifestReleaseRequest(_ request: SpacesDeviceWorkspaceDiffManifestReleaseRequest) -> SpacesDeviceAPIResponse {
        guard !request.manifestID.isEmpty else {
            return SpacesDeviceAPIResponse(ok: false, message: "manifestID is required to release a diff manifest.", errorCode: .invalidArgument)
        }
        guard !(request.lastCommit && SpacesDeviceWorkspaceDiffEngine.normalizedRefName(request.refName) != nil) else {
            return SpacesDeviceAPIResponse(ok: false, message: "lastCommit and refName are mutually exclusive.", errorCode: .invalidArgument)
        }
        let scope = WorkspaceDiffScope(workspaceID: request.workspaceID, refName: request.refName, lastCommit: request.lastCommit)
        switch workspaceDiffTransfers.releaseManifest(manifestID: request.manifestID, scope: scope) {
        case .found: return SpacesDeviceAPIResponse(ok: true, message: "Released workspace diff manifest.")
        case .missing:
            // Release is an idempotent cleanup request. A client may retry after the daemon accepted the
            // first release but lost its response, or release after TTL did the same work.
            return SpacesDeviceAPIResponse(ok: true, message: "Workspace diff manifest was already released or expired.")
        case .mismatched:
            return SpacesDeviceAPIResponse(
                ok: false, message: "Workspace diff manifest does not match this workspace or scope.", errorCode: .invalidArgument)
        }
    }

    private func handleWorkspaceDiffFileChunkRequest(_ request: SpacesDeviceWorkspaceDiffFileChunkRequest, context _: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        guard request.byteOffset >= 0 else {
            return SpacesDeviceAPIResponse(ok: false, message: "byteOffset must not be negative.", errorCode: .invalidArgument)
        }
        guard !request.manifestID.isEmpty else {
            return SpacesDeviceAPIResponse(
                ok: false, message: "manifestID is required for a workspace diff patch range.", errorCode: .invalidArgument)
        }
        guard !(request.lastCommit && SpacesDeviceWorkspaceDiffEngine.normalizedRefName(request.refName) != nil) else {
            return SpacesDeviceAPIResponse(ok: false, message: "lastCommit and refName are mutually exclusive.", errorCode: .invalidArgument)
        }
        let scope = WorkspaceDiffScope(workspaceID: request.workspaceID, refName: request.refName, lastCommit: request.lastCommit)

        if request.cancel {
            guard let transferID = request.transferID, !transferID.isEmpty else {
                return SpacesDeviceAPIResponse(ok: false, message: "transferID is required to cancel a patch transfer.", errorCode: .invalidArgument)
            }
            switch workspaceDiffTransfers.lookupPatch(
                manifestID: request.manifestID, transferID: transferID, scope: scope, relativePath: request.relativePath)
            {
            case .found:
                _ = workspaceDiffTransfers.removePatch(transferID: transferID)
                return SpacesDeviceAPIResponse(ok: true, message: "Cancelled workspace diff patch transfer.")
            case .missing:
                // Cancellation is also idempotent: its only product effect is releasing a private file.
                return SpacesDeviceAPIResponse(ok: true, message: "Workspace diff patch transfer was already cancelled or expired.")
            case .mismatched:
                return SpacesDeviceAPIResponse(
                    ok: false, message: "Workspace diff patch transfer does not match this manifest, workspace, scope, or file.",
                    errorCode: .invalidArgument)
            }
        }

        if request.byteOffset == 0 {
            guard request.transferID == nil else {
                return SpacesDeviceAPIResponse(
                    ok: false, message: "The initial workspace diff patch range must not include transferID.", errorCode: .invalidArgument)
            }
            let manifest: WorkspaceDiffTransferStore.ManifestSession
            switch workspaceDiffTransfers.lookupManifest(manifestID: request.manifestID, scope: scope) {
            case .found(let session): manifest = session
            case .missing:
                return SpacesDeviceAPIResponse(ok: false, message: "Workspace diff manifest expired or was released.", errorCode: .notFound)
            case .mismatched:
                return SpacesDeviceAPIResponse(
                    ok: false, message: "Workspace diff manifest does not match this workspace or scope.", errorCode: .invalidArgument)
            }

            if let existing = workspaceDiffTransfers.lookupPatchForInitialRange(
                manifestID: request.manifestID, scope: scope, relativePath: request.relativePath)
            {
                let transfer = SpacesDeviceWorkspaceDiffEngine.FilePatchTransfer(
                    scopeSignature: existing.patch.scopeSignature, file: existing.patch.file, patchByteCount: existing.patch.byteCount)
                return try workspaceDiffPatchChunkResponse(
                    transferID: existing.transferID, transfer: transfer, byteOffset: 0, outputURL: existing.patch.outputURL)
            }

            let outputURL = try makeWorkspaceDiffPatchTransferFile()
            var retainedByTransfer = false
            defer { if !retainedByTransfer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) } }
            guard
                let transfer = try SpacesDeviceWorkspaceDiffEngine.writeDiffFilePatch(
                    snapshot: manifest.snapshot, workspaceDir: manifest.workspaceDir, relativePath: request.relativePath, outputURL: outputURL,
                    gitClient: workspaceGitClient, deadlineStart: Date())
            else {
                return SpacesDeviceAPIResponse(
                    ok: false, message: "The requested file is not changed in this workspace diff manifest.", errorCode: .notFound)
            }

            // Binary and empty patches have complete metadata but no byte stream. Do not create a transfer
            // that a client could only discover is already complete on a needless second request.
            guard !transfer.file.isBinary, transfer.patchByteCount > 0 else {
                return SpacesDeviceAPIResponse(
                    ok: true, message: "Loaded workspace diff patch metadata.",
                    result: .workspaceDiffFileChunk(.init(scopeSignature: transfer.scopeSignature, file: transfer.file)))
            }

            let transferID = workspaceDiffTransfers.createPatch(
                manifestID: request.manifestID, scope: scope, relativePath: request.relativePath, scopeSignature: transfer.scopeSignature,
                file: transfer.file, outputURL: outputURL, byteCount: transfer.patchByteCount)
            retainedByTransfer = true
            do { return try workspaceDiffPatchChunkResponse(transferID: transferID, transfer: transfer, byteOffset: 0, outputURL: outputURL) } catch {
                _ = workspaceDiffTransfers.removePatch(transferID: transferID)
                throw error
            }
        }

        guard let transferID = request.transferID, !transferID.isEmpty else {
            return SpacesDeviceAPIResponse(
                ok: false, message: "transferID is required after the initial workspace diff patch range.", errorCode: .invalidArgument)
        }
        switch workspaceDiffTransfers.lookupPatch(
            manifestID: request.manifestID, transferID: transferID, scope: scope, relativePath: request.relativePath)
        {
        case .found(let session):
            let transfer = SpacesDeviceWorkspaceDiffEngine.FilePatchTransfer(
                scopeSignature: session.scopeSignature, file: session.file, patchByteCount: session.byteCount)
            do {
                return try workspaceDiffPatchChunkResponse(
                    transferID: transferID, transfer: transfer, byteOffset: request.byteOffset, outputURL: session.outputURL)
            } catch {
                _ = workspaceDiffTransfers.removePatch(transferID: transferID)
                throw error
            }
        case .missing: return SpacesDeviceAPIResponse(ok: false, message: "Workspace diff patch transfer or manifest expired.", errorCode: .notFound)
        case .mismatched:
            return SpacesDeviceAPIResponse(
                ok: false, message: "Workspace diff patch transfer does not match this manifest, workspace, scope, or file.",
                errorCode: .invalidArgument)
        }
    }

    /// Every line-framed Device API response, including base64 and its envelope, fits this transport bound.
    private static let workspaceDiffPatchResponseByteCap = 4 * 1024 * 1024

    private func workspaceDiffPatchChunkResponse(
        transferID: String, transfer: SpacesDeviceWorkspaceDiffEngine.FilePatchTransfer, byteOffset: Int, outputURL: URL
    ) throws -> SpacesDeviceAPIResponse {
        guard Int64(byteOffset) <= transfer.patchByteCount else {
            return SpacesDeviceAPIResponse(ok: false, message: "byteOffset is outside this workspace diff patch.", errorCode: .invalidArgument)
        }
        let rawByteCap = try workspaceDiffPatchInitialRawByteCap(transferID: transferID, transfer: transfer)
        var (bytes, nextByteOffset) = try readWorkspaceDiffPatchChunk(
            at: outputURL, byteOffset: byteOffset, byteCount: transfer.patchByteCount, rawByteCap: rawByteCap)
        var response = workspaceDiffPatchResponse(transferID: transferID, transfer: transfer, bytes: bytes, nextByteOffset: nextByteOffset)
        if try SpacesDeviceAPICodec.encodeResponseLine(response).count > Self.workspaceDiffPatchResponseByteCap {
            let fittedByteCount = try workspaceDiffPatchFittingByteCount(
                transferID: transferID, transfer: transfer, bytes: bytes, byteOffset: byteOffset)
            bytes = Data(bytes.prefix(fittedByteCount))
            nextByteOffset = Int64(byteOffset) + Int64(bytes.count) < transfer.patchByteCount ? byteOffset + bytes.count : nil
            response = workspaceDiffPatchResponse(transferID: transferID, transfer: transfer, bytes: bytes, nextByteOffset: nextByteOffset)
        }
        if nextByteOffset == nil { workspaceDiffTransfers.markPatchComplete(transferID: transferID) }
        let encodedResponseByteCount = try SpacesDeviceAPICodec.encodeResponseLine(response).count
        precondition(
            encodedResponseByteCount <= Self.workspaceDiffPatchResponseByteCap, "Workspace diff patch response exceeded its transport byte cap.")
        return response
    }

    private func workspaceDiffPatchResponse(
        transferID: String, transfer: SpacesDeviceWorkspaceDiffEngine.FilePatchTransfer, bytes: Data, nextByteOffset: Int?
    ) -> SpacesDeviceAPIResponse {
        let isComplete = nextByteOffset == nil
        return SpacesDeviceAPIResponse(
            ok: true, message: "Loaded workspace diff patch chunk.",
            result: .workspaceDiffFileChunk(
                .init(
                    scopeSignature: transfer.scopeSignature, file: transfer.file, transferID: isComplete ? nil : transferID,
                    patchBase64Data: bytes.base64EncodedString(), nextByteOffset: nextByteOffset)))
    }

    /// This first read reserves base64 expansion. The exact serialized response below verifies the
    /// complete transport representation and reduces the range through the same path when needed.
    private func workspaceDiffPatchInitialRawByteCap(transferID: String, transfer: SpacesDeviceWorkspaceDiffEngine.FilePatchTransfer) throws -> Int {
        let reserved = SpacesDeviceAPIResponse(
            ok: true, message: "Loaded workspace diff patch chunk.",
            result: .workspaceDiffFileChunk(
                .init(
                    scopeSignature: transfer.scopeSignature, file: transfer.file, transferID: transferID, patchBase64Data: "", nextByteOffset: Int.max
                )))
        let envelopeBytes = try SpacesDeviceAPICodec.encodeResponseLine(reserved).count
        let base64Groups = max(0, (Self.workspaceDiffPatchResponseByteCap - envelopeBytes) / 4)
        return base64Groups * 3
    }

    /// Finds the largest prefix whose actual encoded response fits. Most base64 payloads fit the initial
    /// budget without entering here; this handles any additional serialized representation overhead.
    private func workspaceDiffPatchFittingByteCount(
        transferID: String, transfer: SpacesDeviceWorkspaceDiffEngine.FilePatchTransfer, bytes: Data, byteOffset: Int
    ) throws -> Int {
        var lowerBound = 0
        var upperBound = bytes.count
        while lowerBound < upperBound {
            let candidateByteCount = (lowerBound + upperBound + 1) / 2
            let candidate = Data(bytes.prefix(candidateByteCount))
            let nextByteOffset = Int64(byteOffset) + Int64(candidateByteCount) < transfer.patchByteCount ? byteOffset + candidateByteCount : nil
            let response = workspaceDiffPatchResponse(transferID: transferID, transfer: transfer, bytes: candidate, nextByteOffset: nextByteOffset)
            if try SpacesDeviceAPICodec.encodeResponseLine(response).count <= Self.workspaceDiffPatchResponseByteCap {
                lowerBound = candidateByteCount
            } else {
                upperBound = candidateByteCount - 1
            }
        }
        return lowerBound
    }

    private func readWorkspaceDiffPatchChunk(at outputURL: URL, byteOffset: Int, byteCount: Int64, rawByteCap: Int) throws -> (Data, Int?) {
        guard let handle = FileHandle(forReadingAtPath: outputURL.path) else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Workspace diff patch transfer is no longer available."])
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(byteOffset))
        let bytes = try handle.read(upToCount: rawByteCap) ?? Data()
        guard !bytes.isEmpty || Int64(byteOffset) == byteCount else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Workspace diff patch transfer was truncated before its expected end."])
        }
        let nextOffset = Int64(byteOffset) + Int64(bytes.count)
        return (bytes, nextOffset < byteCount ? Int(nextOffset) : nil)
    }

    /// Creates one 0700 UUID directory and one 0600 empty output file. `git diff --output` writes only to
    /// that private, daemon-minted path; no client path is ever used for the transfer artifact.
    private func makeWorkspaceDiffPatchTransferFile() throws -> URL {
        let fileManager = FileManager.default
        for _ in 0..<3 {
            let directory = fileManager.temporaryDirectory.appendingPathComponent("spaces-workspace-diff-\(UUID().uuidString)", isDirectory: true)
            do { try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) } catch {
                continue  // UUID collision or transient temp-dir race: mint another unique directory.
            }
            let outputURL = directory.appendingPathComponent("patch", isDirectory: false)
            if fileManager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) { return outputURL }
            try? fileManager.removeItem(at: directory)
        }
        throw NSError(
            domain: "SpacesDeviceAPIServer", code: 500,
            userInfo: [NSLocalizedDescriptionKey: "Could not create workspace diff patch transfer storage."])
    }

    private func handleUpdateProjectConfigRequest(_ request: SpacesDeviceProjectConfigUpdateRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        try context.orchestrator().updateProjectConfig(projectID: request.projectID, updateAllWorkspaces: request.updateAllWorkspaces) { config in
            config.setupScript = normalizedOptionalString(request.config.setupScript)
            config.stopScript = normalizedOptionalString(request.config.stopScript)
            config.ports = request.config.ports.map(workspacePort)
            config.processes = request.config.processes.map(workspaceProcess)
            config.browserSessions = request.config.browserSessions.map(workspaceBrowserSession)
        }
        return try refreshedMutationResponse(context: context, message: "Updated project settings.", projectID: request.projectID)
    }

    private func handleUpdateProjectMetadataRequest(_ request: SpacesDeviceProjectMetadataUpdateRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let orchestrator = try context.orchestrator()
        if request.updatesHidden {
            try context.store().withTransaction {
                try orchestrator.updateProjectHidden(projectID: request.projectID, isHidden: request.isHidden == true)
            }
        }
        return try refreshedMutationResponse(context: context, message: "Updated project metadata.", projectID: request.projectID)
    }

    private func handleUpdateWorkspaceConfigRequest(_ request: SpacesDeviceWorkspaceConfigUpdateRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        try context.orchestrator().updateWorkspaceSettings(workspaceID: request.workspaceID) { config in
            config.stopScript = normalizedOptionalString(request.config.stopScript)
            config.ports = request.config.ports.map(workspacePort)
            config.processes = request.config.processes.map(workspaceProcess)
            config.browserSessions = request.config.browserSessions.map(workspaceBrowserSession)
        }
        return try refreshedMutationResponse(context: context, message: "Updated workspace settings.", workspaceID: request.workspaceID)
    }

    private func handleUpdateWorkspaceMetadataRequest(_ request: SpacesDeviceWorkspaceMetadataUpdateRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let orchestrator = try context.orchestrator()
        if request.updatesBranch {
            try orchestrator.updateWorkspaceMetadata(workspaceID: request.workspaceID, branch: normalizedString(request.branch) ?? "")
        }
        if request.updatesNotes || request.updatesHidden {
            try context.store().withTransaction {
                if request.updatesNotes {
                    try orchestrator.updateWorkspaceNotes(workspaceID: request.workspaceID, notes: normalizedOptionalString(request.notes))
                }
                if request.updatesHidden {
                    try orchestrator.updateWorkspaceHidden(workspaceID: request.workspaceID, isHidden: request.isHidden == true)
                }
            }
        }
        return try refreshedMutationResponse(context: context, message: "Updated workspace metadata.", workspaceID: request.workspaceID)
    }

    private static func wireReviewCommentSide(_ side: WorkspaceReviewCommentSide) -> SpacesDeviceReviewCommentSide {
        switch side {
        case .old: .old
        case .new: .new
        }
    }

    private static func storeReviewCommentSide(_ side: SpacesDeviceReviewCommentSide) -> WorkspaceReviewCommentSide {
        switch side {
        case .old: .old
        case .new: .new
        }
    }

    private static func wireReviewComment(from record: WorkspaceReviewCommentRecord) -> SpacesDeviceReviewComment {
        SpacesDeviceReviewComment(
            id: record.id, filePath: record.filePath, side: wireReviewCommentSide(record.side), lineNumber: record.lineNumber,
            lineText: record.lineText, body: record.body, createdAt: record.createdAt, revision: record.revision)
    }

    /// round-13 Fix 3: stays on the main serial device-API queue and does not take `reviewCommentQueue` — it
    /// is a read-only draft list with no compare-then-write step to protect, unlike upsert/delete/send below
    /// (all diverted to a terminal-control lane; see `runsOnTerminalControlLane`).
    private func handleWorkspaceReviewCommentListRequest(_ request: SpacesDeviceWorkspaceReviewCommentListRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        _ = try resolveWorkspaceDirectory(workspaceID: request.workspaceID, context: context)
        let drafts = try context.store().reviewCommentDrafts(workspaceID: request.workspaceID)
        return SpacesDeviceAPIResponse(
            ok: true, message: "Listed review comments.",
            result: .workspaceReviewCommentList(.init(comments: drafts.map(Self.wireReviewComment(from:)))))
    }

    /// Creates a draft when `request.id` is nil, or updates an existing one's body/anchor when it names a
    /// draft this workspace owns. Rejects an `id` naming another workspace's comment or an already-sent
    /// (archived) one, rather than silently creating an unrelated new draft under that id — and, the same
    /// way, rejects an `id` that names no comment at all (`.notFound`, mirroring
    /// `handleWorkspaceReviewCommentDeleteRequest`) rather than silently creating a fresh draft under a
    /// caller-supplied id the store never issued. Only a nil `id` is a create.
    ///
    /// Runs on a terminal-control lane (see `runsOnTerminalControlLane`), which has no
    /// `RequestContext` of its own, so — mirroring `handleWorkspaceReviewCommentsSendRequest` — this opens
    /// its own `SQLiteStore` directly instead of depending on one. Its store read+write body still runs
    /// inside `reviewCommentQueue.sync` (see that queue's doc comment) so it cannot interleave with a
    /// `.workspaceReviewCommentsSend` mid-flight on the same draft.
    private func handleWorkspaceReviewCommentUpsertRequest(_ request: SpacesDeviceWorkspaceReviewCommentUpsertRequest) throws
        -> SpacesDeviceAPIResponse
    {
        guard !request.filePath.isEmpty else {
            return SpacesDeviceAPIResponse(ok: false, message: "filePath is required.", errorCode: .invalidArgument)
        }
        guard !request.body.isEmpty else { return SpacesDeviceAPIResponse(ok: false, message: "body is required.", errorCode: .invalidArgument) }
        return try reviewCommentQueue.sync {
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            guard try store.workspace(id: request.workspaceID) != nil else {
                return SpacesDeviceAPIResponse(ok: false, message: "Workspace '\(request.workspaceID)' was not found.", errorCode: .notFound)
            }
            // Accepted risk (round-12): no revision check on this read-modify-write, so a concurrent
            // upsert of the same draft from another pane is last-write-wins — see the request struct's
            // doc comment in SpacesDeviceAPIProtocol.swift. Only `reviewCommentsSend` enforces a revision.
            var existing: WorkspaceReviewCommentRecord?
            if let id = request.id {
                guard let found = try store.reviewComment(id: id) else {
                    return SpacesDeviceAPIResponse(ok: false, message: "Comment '\(id)' was not found.", errorCode: .notFound)
                }
                if found.workspaceID != request.workspaceID {
                    return SpacesDeviceAPIResponse(
                        ok: false, message: "Comment '\(id)' does not belong to this workspace.", errorCode: .invalidArgument)
                }
                if found.sentAt != nil {
                    return SpacesDeviceAPIResponse(
                        ok: false, message: "Comment '\(id)' was already sent and cannot be edited.", errorCode: .invalidArgument)
                }
                existing = found
            }
            let now = TerminalSessionTimestamp.string(from: Date())
            // `revision` is bound only for the case `upsertReviewComment` treats as a fresh INSERT (no
            // `existing` row); its `ON CONFLICT` arm bumps the stored column itself (`revision =
            // ...revision + 1`) and ignores this bound value, so `existing?.revision` here is never actually
            // written on an update — it just satisfies the record's initializer.
            //
            // round-14 accepted risk: a create whose response is lost after `upsertReviewComment` below
            // commits (e.g. the connection drops between commit and delivery) leaves the client's card
            // stuck "provisional"; the client's natural retry-on-no-response then inserts a SECOND row
            // (`request.id` is nil on that retry too, so `UUID().uuidString` mints a new id) for what the
            // user perceives as one comment. Not fixed for v1: the window is narrow (response lost in that
            // specific gap, then a retry landing), the symptom is just a duplicate draft card the user can
            // delete like any other, and the real fix — client-selected ids with create-if-missing/upsert-
            // by-client-id semantics — would weaken the already-sent guard just above, which currently trusts
            // that an `id` naming an existing row is a real edit intent rather than a possibly-colliding
            // client-chosen id.
            let record = WorkspaceReviewCommentRecord(
                id: request.id ?? UUID().uuidString, workspaceID: request.workspaceID, filePath: request.filePath,
                side: Self.storeReviewCommentSide(request.side), lineNumber: request.lineNumber, lineText: request.lineText, body: request.body,
                createdAt: existing?.createdAt ?? now, updatedAt: now, revision: existing?.revision ?? 0, sentAt: nil)
            try store.upsertReviewComment(record)
            // Re-read rather than echo `record`: on an update, the store computed the actual persisted
            // `revision` itself (see above), so `record.revision` is not what's on disk — the client's local
            // mirror must get the real value or its next send would compare against a stale one and fail
            // `.conflict` on a draft it just saved successfully.
            guard let persisted = try store.reviewComment(id: record.id) else {
                preconditionFailure("Review comment '\(record.id)' vanished immediately after being upserted on the same request handler.")
            }
            return SpacesDeviceAPIResponse(
                ok: true, message: "Saved review comment.",
                result: .workspaceReviewCommentUpsert(.init(comment: Self.wireReviewComment(from: persisted))))
        }
    }

    /// Runs its store read+write body on `reviewCommentQueue` for the same reason as the upsert handler above:
    /// closes the window where a delete could remove a draft a concurrent send just validated against.
    ///
    /// Delete is a DRAFT-only operation: only a comment with `sentAt == nil` can be removed. The archive is
    /// append-only from the client's perspective — once a comment is sent, no client request can erase that
    /// durable record, matching the upsert handler's own already-sent protection against edits above.
    ///
    /// Like the upsert handler above, this runs on a terminal-control lane and so has no
    /// `RequestContext` — it opens its own `SQLiteStore` directly, mirroring `handleWorkspaceReviewCommentsSendRequest`.
    private func handleWorkspaceReviewCommentDeleteRequest(_ request: SpacesDeviceWorkspaceReviewCommentDeleteRequest) throws
        -> SpacesDeviceAPIResponse
    {
        return try reviewCommentQueue.sync {
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            guard try store.workspace(id: request.workspaceID) != nil else {
                return SpacesDeviceAPIResponse(ok: false, message: "Workspace '\(request.workspaceID)' was not found.", errorCode: .notFound)
            }
            guard let existing = try store.reviewComment(id: request.id), existing.workspaceID == request.workspaceID else {
                return SpacesDeviceAPIResponse(ok: false, message: "Comment '\(request.id)' was not found.", errorCode: .notFound)
            }
            guard existing.sentAt == nil else {
                return SpacesDeviceAPIResponse(
                    ok: false, message: "Comment '\(request.id)' was already sent and cannot be deleted.", errorCode: .invalidArgument)
            }
            try store.deleteReviewComment(id: request.id)
            return SpacesDeviceAPIResponse(ok: true, message: "Deleted review comment.")
        }
    }

    /// Writes `request.text` to `request.sessionID`'s terminal input using the same control-socket path
    /// `handleSendTerminalInputRequest` uses, then — only if that write succeeds — marks every entry in
    /// `request.comments` sent. Composing send-then-archive here rather than as two client calls is what
    /// guarantees a comment is never archived unless its text was actually sent (the daemon-side write and
    /// archive can't be split by a client crash between them the way two separate calls could); the
    /// converse — a comment that was sent always ends up archived — is not guaranteed (a daemon crash
    /// between the write and `markReviewCommentsSent` below would leave it sent-but-still-draft), an
    /// accepted low-probability gap since a client whose send timed out already has to reconcile by
    /// re-reading the draft list. See docs/implementation.md for the fuller rationale.
    ///
    /// Each entry's `revision` is checked against the draft's current one before anything is written:
    /// the client's local mirror was read at some point in the past and may be stale (another edit landed
    /// on the same draft — this client or another surface entirely — since then), and sending its
    /// possibly-outdated `text` composed from that stale body would silently discard the newer edit once
    /// the comment is archived. A mismatch is a version conflict, not a missing-argument or ownership
    /// problem, hence `.conflict` rather than `.invalidArgument` for that one check. `revision` (not
    /// `updatedAt`) is the token: `updatedAt` has whole-second resolution, so two edits inside the same
    /// second would leave it unchanged and this check would silently pass over genuinely stale text.
    ///
    /// Runs on a terminal-control lane (see `runsOnTerminalControlLane`), which has no `RequestContext` of
    /// its own — mirrors `computeWorkspaceDiffScopeSignature`'s "a store belongs to the queue that opened
    /// it" confinement rule by opening its own `SQLiteStore` here rather than sharing one from `queue`.
    ///
    /// The entire body additionally runs inside `try reviewCommentQueue.sync` (see that queue's doc comment):
    /// every comment's `revision` is checked up front, but the session/runtime validation, the terminal-control
    /// write, and `markReviewCommentsSent` below all happen afterward — without this queue, an upsert could
    /// still land in that gap and get silently overwritten by the stale text this handler already validated as
    /// fresh. Blocking `reviewCommentQueue` for the control-socket round trip's duration is acceptable: it is a
    /// local unix-domain-socket call (not network), bounded by `TerminalControlClient.send`'s own timeout, and
    /// review-comment sends are always a direct user click, never a hot path — a few extra ms of queue
    /// contention on the rare concurrent edit buys out the TOCTOU. This nests `reviewCommentQueue.sync` inside
    /// the outer terminal-control lane that routed the request here; that is safe only because they are
    /// distinct queue objects and nothing this body calls — `SQLiteStore`, `TerminalControlClient.send`,
    /// `TerminalSessionPersistence` — dispatches back onto either queue (verified: none of the three uses
    /// `DispatchQueue` at all).
    private func handleWorkspaceReviewCommentsSendRequest(_ request: SpacesDeviceWorkspaceReviewCommentsSendRequest) throws -> SpacesDeviceAPIResponse
    {
        guard !request.comments.isEmpty else {
            return SpacesDeviceAPIResponse(ok: false, message: "comments is required.", errorCode: .invalidArgument)
        }
        return try reviewCommentQueue.sync {
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            guard try store.workspace(id: request.workspaceID) != nil else {
                return SpacesDeviceAPIResponse(ok: false, message: "Workspace '\(request.workspaceID)' was not found.", errorCode: .notFound)
            }
            for entry in request.comments {
                guard let comment = try store.reviewComment(id: entry.id), comment.workspaceID == request.workspaceID, comment.sentAt == nil else {
                    return SpacesDeviceAPIResponse(
                        ok: false, message: "Comment '\(entry.id)' is not a draft belonging to this workspace.", errorCode: .invalidArgument)
                }
                guard comment.revision == entry.revision else {
                    return SpacesDeviceAPIResponse(ok: false, message: "Comment '\(entry.id)' changed since it was last read.", errorCode: .conflict)
                }
            }

            // Validate the session belongs to this workspace and is running. `handleSendTerminalInputRequest`
            // (the general-purpose terminal-send endpoint this reuses below) does neither check — its callers
            // (agent tooling, client typing) already hold a session the caller is known to own — so this
            // composes both checks fresh from the session's persisted launch configuration and runtime state.
            let paths = try TerminalSessionPaths.forSession(id: request.sessionID)
            guard let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths),
                launchConfiguration.workspaceID == request.workspaceID
            else {
                return SpacesDeviceAPIResponse(
                    ok: false, message: "Terminal session '\(request.sessionID)' does not belong to this workspace.", errorCode: .invalidArgument)
            }
            guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), runtimeState.state.isInteractive else {
                return SpacesDeviceAPIResponse(
                    ok: false, message: "Terminal session '\(request.sessionID)' is not running.", errorCode: .sessionNotRunning)
            }
            guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
                return SpacesDeviceAPIResponse(
                    ok: false, message: "Terminal session '\(request.sessionID)' is not available.", errorCode: .sessionNotAvailable)
            }
            // The interactive runtime can outlive the agent process as a bare shell. Re-read the agent
            // row immediately before writing so a session that has since exited cannot receive review text
            // merely because its launch configuration and control socket are still present.
            guard let agent = try store.agentWindowByTerminalSession(terminalSessionID: request.sessionID), agent.workspaceID == request.workspaceID,
                agent.status != .exited
            else {
                return SpacesDeviceAPIResponse(
                    ok: false, message: "Terminal session '\(request.sessionID)' is not an active coding agent.", errorCode: .invalidArgument)
            }

            // `appendNewline: true` is what makes `handleSendTerminalInputRequest`'s underlying PTY write
            // submit a bracketed-paste write with a separate CR (0x0D) afterward (see
            // `GhosttyEmbeddedSessionHost.controlResponseForSendRequest`) — embedded LFs inside a bracketed
            // paste are literal content to a TUI's line editor, not an Enter keypress, so this always
            // submits rather than leaving the comment sitting unsent in the agent's input buffer.
            let sendResponse = try TerminalControlClient.send(
                request: TerminalControlRequest(
                    command: .send(TerminalControlSendPayload(text: request.text, bytes: nil, clientID: nil, ownerEpoch: nil, appendNewline: true))),
                socketPath: paths.controlSocketPath)
            guard sendResponse.ok else { return SpacesDeviceAPIResponse(ok: false, message: sendResponse.message, errorCode: sendResponse.errorCode) }

            try store.markReviewCommentsSent(ids: request.comments.map(\.id), sentAt: TerminalSessionTimestamp.string(from: Date()))
            return SpacesDeviceAPIResponse(ok: true, message: "Sent review comments.")
        }
    }

    private func handleOpenWorkspaceTerminalRequest(_ request: SpacesDeviceWorkspaceReference, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        let orchestrator = try context.orchestrator()
        let reservation = try orchestrator.reserveWorkspaceTerminalLaunch(workspaceID: workspaceID)
        let response: SpacesDeviceAPIResponse
        do {
            response = try refreshedMutationResponse(
                context: context, message: "Opened workspace terminal.", workspaceID: workspaceID, sessionID: reservation.sessionID)
        } catch {
            orchestrator.cancelReservedWorkspaceTerminalLaunch(reservation)
            throw error
        }
        finishReservedWorkspaceTerminalLaunchInBackground(reservation)
        return response
    }

    /// Starts an arbitrary command in a workspace-owned terminal. This is intentionally distinct from
    /// `spawnAgentSession`: the latter is a CLI/MCP contract that rejects unrecognized commands, whereas
    /// Editor's Start Agent dialog accepts the command the user supplies and waits for ordinary foreground
    /// detection to decide whether it becomes an addressable coding agent.
    private func handleStartWorkspaceCommandSessionRequest(_ request: SpacesDeviceStartWorkspaceCommandSessionRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        guard !request.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SpacesDeviceAPIResponse(ok: false, message: "command is required.", errorCode: .invalidArgument)
        }
        let session = try context.orchestrator().createWorkspaceTerminalSession(workspaceID: request.workspaceID, title: nil, command: request.command)
        return try refreshedMutationResponse(
            context: context, message: "Started workspace command session.", workspaceID: request.workspaceID, sessionID: session.id,
            launchedTerminalSession: try launchedTerminalSessionSummary(session, workspaceID: request.workspaceID))
    }

    private func handleStopWorkspaceTerminalRequest(_ request: SpacesDeviceWorkspaceTerminalRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        let sessionID = request.sessionID
        let orchestrator = try context.orchestrator()
        if let runID = try context.store().automationRunID(terminalSessionID: sessionID), let run = try context.store().automationRun(id: runID) {
            guard let automationOperations else {
                return SpacesDeviceAPIResponse(ok: false, message: "Automations are unavailable on this daemon.", errorCode: .internalError)
            }
            // Only a cancellation that actually won while the run was active owns Stop outright. The
            // service can serialize behind a completion: its returned terminal status then leaves a live
            // agent session for the normal agent/session path below.
            let wasActiveBeforeCancel = !run.status.isTerminal
            let canceledRun = try automationOperations.cancelRun(runID)
            if wasActiveBeforeCancel, canceledRun.status == .canceled {
                return try refreshedMutationResponse(context: context, message: "Canceled automation run.", workspaceID: workspaceID)
            }
        }
        // A hook-registered agent can run inside a configured process terminal. Its launch kind stays
        // `.process`, so resolve the persisted agent row before the `.agent` launch-kind check reserved for
        // pre-signal sessions.
        let isRegisteredAgent = try context.store().agentWindowByTerminalSession(terminalSessionID: sessionID) != nil
        if isRegisteredAgent || orchestrator.workspaceTerminalSessionIsSpawnedAgent(workspaceID: workspaceID, sessionID: sessionID) {
            guard let agentSessionKiller else {
                return SpacesDeviceAPIResponse(ok: false, message: "Agent stop is unavailable on this daemon.", errorCode: .internalError)
            }
            guard try agentSessionKiller(sessionID) else {
                return try refreshedMutationResponse(context: context, message: "Workspace terminal was already stopped.", workspaceID: workspaceID)
            }
            return try refreshedMutationResponse(context: context, message: "Stopped workspace terminal.", workspaceID: workspaceID)
        }
        guard try orchestrator.stopAdHocBuiltInTerminalSession(workspaceID: workspaceID, sessionID: sessionID) else {
            return try refreshedMutationResponse(context: context, message: "Workspace terminal was already stopped.", workspaceID: workspaceID)
        }
        return try refreshedMutationResponse(context: context, message: "Stopped workspace terminal.", workspaceID: workspaceID)
    }

    /// Serves the close of the pane that owned an ad hoc terminal: the daemon decides whether the
    /// terminal is idle at a bare prompt and only then stops it (see
    /// `stopAdHocBuiltInTerminalSessionIfForegroundIsBareShell`). Both outcomes are a success (keeping a
    /// busy terminal is the point of the request, not a failure of it), so the response reports which one
    /// happened rather than an error code.
    private func handleStopWorkspaceTerminalIfBareShellRequest(_ request: SpacesDeviceWorkspaceTerminalRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        let terminated = try context.orchestrator().stopAdHocBuiltInTerminalSessionIfForegroundIsBareShell(
            workspaceID: workspaceID, sessionID: request.sessionID)
        return try refreshedMutationResponse(
            context: context, message: terminated ? "Stopped workspace terminal." : "Kept workspace terminal.", workspaceID: workspaceID,
            terminatedTerminalSession: terminated)
    }

    private func handleRenameTerminalSessionRequest(_ request: SpacesDeviceTerminalSessionRenameRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        let sessionID = request.sessionID
        // An empty title clears the rename, restoring the generated name (see
        // `SpacesDeviceTerminalSessionRenameRequest.title`).
        let title = normalizedString(request.title)
        guard try context.orchestrator().renameAdHocBuiltInTerminalSession(workspaceID: workspaceID, sessionID: sessionID, title: title ?? "") else {
            return SpacesDeviceAPIResponse(
                ok: false, message: "Terminal session '\(sessionID)' is not a renamable workspace terminal.", errorCode: .invalidArgument)
        }
        return try refreshedMutationResponse(
            context: context, message: title == nil ? "Cleared terminal session name." : "Renamed terminal session.", workspaceID: workspaceID,
            sessionID: sessionID)
    }

    private func handleRunWorkspaceProcessRequest(_ request: SpacesDeviceRunWorkspaceProcessRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        let processKey = request.processKey
        let orchestrator = try context.orchestrator()
        let record =
            if let processTemplateID = normalizedString(request.processTemplateID) {
                try orchestrator.runConfiguredProcess(workspaceID: workspaceID, processTemplateID: processTemplateID, processKey: processKey)
            } else { try orchestrator.runConfiguredProcess(workspaceID: workspaceID, processKey: processKey) }
        return try refreshedMutationResponse(
            context: context, message: "Ran process '\(processKey)'.", workspaceID: workspaceID,
            sessionID: normalizedString(record.terminalTrackingID))
    }

    private func handleStopWorkspaceProcessRequest(_ request: SpacesDeviceWorkspaceProcessMutationRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        let processID = try resolvedRunningProcessID(request: request, store: context.store())
        try context.orchestrator().stopWorkspaceProcess(workspaceID: workspaceID, processID: processID)
        return try refreshedMutationResponse(context: context, message: "Stopped process.", workspaceID: workspaceID)
    }

    private func handleRestartWorkspaceProcessRequest(_ request: SpacesDeviceWorkspaceProcessMutationRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        let processID = try resolvedRunningProcessID(request: request, store: context.store())
        try context.orchestrator().restartWorkspaceProcess(workspaceID: workspaceID, processID: processID)
        return try refreshedMutationResponse(context: context, message: "Restarted process.", workspaceID: workspaceID)
    }

    private func handleStopCodingAgentRequest(_ request: SpacesDeviceCodingAgentMutationRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        guard let agentID = normalizedString(request.agentID) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Missing coding agent ID.", errorCode: .invalidArgument)
        }
        try context.orchestrator().stopCodingAgent(workspaceID: workspaceID, agentID: agentID)
        return try refreshedMutationResponse(context: context, message: "Stopped coding agent.", workspaceID: workspaceID)
    }

    /// Renames a coding-agent row, whose name is stored on its session. An empty title clears the rename,
    /// restoring the name the agent reports for itself (see `SpacesDeviceAgentSessionRenameRequest.title`);
    /// an id that names no agent session in the workspace throws from the orchestrator and is reported as a
    /// failure.
    private func handleRenameAgentSessionRequest(_ request: SpacesDeviceAgentSessionRenameRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        guard let agentID = normalizedString(request.agentID) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Missing coding agent ID.", errorCode: .invalidArgument)
        }
        let title = normalizedString(request.title)
        try context.orchestrator().renameAgentSession(workspaceID: workspaceID, agentID: agentID, title: title ?? "")
        return try refreshedMutationResponse(
            context: context, message: title == nil ? "Cleared coding agent name." : "Renamed coding agent.", workspaceID: workspaceID)
    }

    /// Spawns a coding-agent terminal session on the daemon host. Runs the same command gate as the
    /// local `spaces agent spawn` — the command must launch a supported coding agent (see `CodingAgent`).
    /// Hooks are not required. Unlike the local path there is no cwd to infer the workspace
    /// from, so `workspaceID` is required. Returns the created session id (as a mutation).
    ///
    /// Remote spawn readiness is detection-based, matching the local path: the client polls the device
    /// overview's terminal session summary for `foregroundDetectedAgentKind`, which the overview builder
    /// populates from the session's live runtime state. That field reports a detected kind before the
    /// session's first hook signal, when no agent-orchestration row exists yet, so `listAgentSessions`
    /// (which enumerates only signaled agent rows) cannot serve remote readiness.
    private func handleSpawnAgentSessionRequest(_ request: SpacesDeviceSpawnAgentSessionRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        guard let workspaceID = normalizedString(request.workspaceID) else {
            return SpacesDeviceAPIResponse(ok: false, message: "workspaceID is required.", errorCode: .invalidArgument)
        }
        guard let command = normalizedString(request.command) else {
            return SpacesDeviceAPIResponse(ok: false, message: "command is required.", errorCode: .invalidArgument)
        }
        do { _ = try AgentSpawnCommandGate.resolveSpawnableAgent(command: command) } catch let error as AgentSpawnCommandGate.GateError {
            return SpacesDeviceAPIResponse(
                ok: false, message: error.errorDescription ?? "Agent spawn command is not supported.", errorCode: .invalidArgument)
        }
        let session = try context.orchestrator().createWorkspaceAgentSession(
            workspaceID: workspaceID, command: command, title: normalizedString(request.title),
            automationRunID: normalizedString(request.automationRunID))
        return try refreshedMutationResponse(context: context, message: "Started agent session.", workspaceID: workspaceID, sessionID: session.id)
    }

    private func handleListAgentSessionsRequest(_ request: SpacesDeviceListAgentSessionsRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let rows = try context.orchestrator().agentSessionRows(
            workspaceID: normalizedString(request.workspaceID), sessionID: normalizedString(request.sessionID))
        return SpacesDeviceAPIResponse(
            ok: true, message: "Listed agent sessions.", result: .agentSessions(.init(rows: rows.map(Self.deviceAgentSessionRow))))
    }

    private func handleAnnotateAgentSessionRequest(_ request: SpacesDeviceAnnotateAgentSessionRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        guard let sessionID = normalizedString(request.sessionID) else {
            return SpacesDeviceAPIResponse(ok: false, message: "sessionID is required.", errorCode: .invalidArgument)
        }
        let row = try context.orchestrator().annotateAgentSession(terminalSessionID: sessionID, note: request.note)
        return SpacesDeviceAPIResponse(
            ok: true, message: row.note == nil ? "Cleared agent note." : "Annotated agent session.",
            result: .agentSessions(.init(rows: [Self.deviceAgentSessionRow(row)])))
    }

    /// Terminates a coding-agent terminal session on the daemon host by session id. This is the remote
    /// counterpart of the local `.agentKill` terminate branch (`killProfileAgentSession`): once the CLI
    /// has confirmed there is no agent row to `stopCodingAgent`, this tears down the raw session. The
    /// orchestrator's `terminateSpawnedAgentTerminalSession(sessionID:)` resolves the session's owning
    /// workspace itself (a spawned agent session is a workspace-owned built-in terminal), so no
    /// `workspaceID` is required — that is exactly what a pre-signal remote kill cannot supply. A session
    /// that is not a tracked built-in terminal is a loud error, not a silent no-op.
    /// Kills a coding-agent session by its child terminal session id. Delegates to the injected
    /// `agentSessionKiller`, which runs the daemon's notify-then-stop `killAgentSession` flow (a
    /// hook-signaled child's subscribers are told it exited before the row is deleted; a not-yet-signaled
    /// `.agent`-kind session is terminated). A false return means the id names no agent session — the same
    /// loud error the local `.agentKill` path raises. A nil killer means the daemon never wired the flow,
    /// so the endpoint is unavailable.
    private func handleKillAgentSessionRequest(_ request: SpacesDeviceKillAgentSessionRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        guard let sessionID = normalizedString(request.sessionID) else {
            return SpacesDeviceAPIResponse(ok: false, message: "sessionID is required.", errorCode: .invalidArgument)
        }
        guard let agentSessionKiller else {
            return SpacesDeviceAPIResponse(ok: false, message: "Agent kill is unavailable on this daemon.", errorCode: .internalError)
        }
        guard try agentSessionKiller(sessionID) else {
            return SpacesDeviceAPIResponse(ok: false, message: "No agent session for terminal \(sessionID).", errorCode: .invalidArgument)
        }
        return try refreshedMutationResponse(context: context, message: "Killed agent session \(sessionID).")
    }

    // MARK: - Automations

    /// The remote counterparts of the profile-socket automation commands. Each routes through the injected
    /// `automationOperations` (the daemon's one live scheduler), so a create/trigger/cancel over the Device
    /// API drives the exact scheduler state a local profile command would. Validation and next-fire-time
    /// recomputation happen inside the shared `AutomationService`, not here.
    private func handleCreateAutomationRequest(_ payload: TerminalServiceAutomationFields) throws -> SpacesDeviceAPIResponse {
        guard let automationOperations else { return automationsUnavailableResponse() }
        let draft = try automationDraft(from: payload)
        let automation = try automationOperations.create(draft)
        return automationsResponse([automation], message: "Created automation.")
    }

    private func handleUpdateAutomationRequest(_ payload: TerminalServiceAutomationUpdatePayload) throws -> SpacesDeviceAPIResponse {
        guard let automationOperations else { return automationsUnavailableResponse() }
        let draft = try automationDraft(from: payload.fields)
        let automation = try automationOperations.update(payload.id, draft)
        return automationsResponse([automation], message: "Updated automation.")
    }

    private func handleSetAutomationNextRunRequest(_ payload: TerminalServiceAutomationNextRunPayload) throws -> SpacesDeviceAPIResponse {
        guard let automationOperations else { return automationsUnavailableResponse() }
        let automation = try automationOperations.setNextRun(payload.id, payload.nextRunTime)
        return automationsResponse([automation], message: "Scheduled next automation run.")
    }

    private func handleDeleteAutomationRequest(_ payload: SpacesDeviceAutomationReference) throws -> SpacesDeviceAPIResponse {
        guard let automationOperations else { return automationsUnavailableResponse() }
        try automationOperations.delete(payload.id)
        return automationsResponse([], message: "Deleted automation.")
    }

    private func handleListAutomationsRequest() throws -> SpacesDeviceAPIResponse {
        guard let automationOperations else { return automationsUnavailableResponse() }
        return automationsResponse(try automationOperations.list(), message: "Listed automations.")
    }

    private func handleListAutomationRunsRequest(_ payload: TerminalServiceAutomationRunsListPayload, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        guard let automationOperations else { return automationsUnavailableResponse() }
        let runs = try automationOperations.runs(normalizedString(payload.automationID))
        return try automationRunsResponse(runs, context: context, message: "Listed automation runs.")
    }

    private func handleTriggerAutomationRequest(_ payload: SpacesDeviceAutomationReference, context: RequestContext) throws -> SpacesDeviceAPIResponse
    {
        guard let automationOperations else { return automationsUnavailableResponse() }
        let run = try automationOperations.trigger(payload.id)
        return try automationRunsResponse([run], context: context, message: "Triggered automation.")
    }

    private func handleCancelAutomationRunRequest(_ payload: SpacesDeviceAutomationRunReference, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        guard let automationOperations else { return automationsUnavailableResponse() }
        let run = try automationOperations.cancelRun(payload.runID)
        return try automationRunsResponse([run], context: context, message: "Canceled automation run.")
    }

    private func handleEndAutomationAgentsRequest(_ payload: SpacesDeviceAutomationRunReference, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        guard let automationOperations else { return automationsUnavailableResponse() }
        let run = try automationOperations.endAgents(payload.runID)
        return try automationRunsResponse([run], context: context, message: "Ended automation run agents.")
    }

    private func automationsUnavailableResponse() -> SpacesDeviceAPIResponse {
        SpacesDeviceAPIResponse(ok: false, message: "Automations are unavailable on this daemon.", errorCode: .internalError)
    }

    private static func invalidArgumentError(_ message: String) -> NSError {
        NSError(domain: "SpacesDeviceAPIServer", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func automationsResponse(_ automations: [Automation], message: String) -> SpacesDeviceAPIResponse {
        SpacesDeviceAPIResponse(ok: true, message: message, result: .automations(.init(rows: automations.map(TerminalServiceAutomationSummary.init))))
    }

    private func automationRunsResponse(_ runs: [AutomationRun], context: RequestContext, message: String) throws -> SpacesDeviceAPIResponse {
        SpacesDeviceAPIResponse(
            ok: true, message: message, result: .automationRuns(.init(rows: try automationRunSummaries(runs, store: context.store()))))
    }

    private func automationDraft(from fields: TerminalServiceAutomationFields) throws -> AutomationDraft {
        guard let triggerKind = AutomationTriggerKind(rawValue: fields.triggerKind) else {
            throw Self.invalidArgumentError("Unsupported automation trigger kind '\(fields.triggerKind)'.")
        }
        guard let kind = AutomationKind(rawValue: fields.kind) else {
            throw Self.invalidArgumentError("Unsupported automation kind '\(fields.kind)'.")
        }
        guard let concurrencyPolicy = AutomationConcurrencyPolicy(rawValue: fields.concurrencyPolicy) else {
            throw Self.invalidArgumentError("Unsupported automation concurrency policy '\(fields.concurrencyPolicy)'.")
        }
        guard let missedRunPolicy = AutomationMissedRunPolicy(rawValue: fields.missedRunPolicy) else {
            throw Self.invalidArgumentError("Unsupported automation missed-run policy '\(fields.missedRunPolicy)'.")
        }
        return AutomationDraft(
            name: fields.name, enabled: fields.enabled, triggerKind: triggerKind, cronExpression: fields.cronExpression, kind: kind,
            script: fields.script, agentCommand: fields.agentCommand, agentPrompt: fields.agentPrompt, workspaceID: fields.workspaceID,
            timeoutSeconds: fields.timeoutSeconds, concurrencyPolicy: concurrencyPolicy, missedRunPolicy: missedRunPolicy)
    }

    /// Maps runs to wire summaries, denormalizing each run's automation name and its attributed coding-agent
    /// breakdown (built once for the whole listing against the daemon's current live-session set).
    private func automationRunSummaries(_ runs: [AutomationRun], store: SQLiteStore) throws -> [TerminalServiceAutomationRunSummary] {
        guard !runs.isEmpty else { return [] }
        let liveSessions = (try? liveTerminalSessions()) ?? []
        let attributedAgentsByRunID = try AutomationAttributedAgents.summariesByRunID(runs: runs, store: store, liveSessions: liveSessions)
        let workspaceIDsByRunID = try store.workspaceIDs(automationRunIDs: runs.map(\.id))
        var namesByAutomationID: [String: String] = [:]
        return try runs.map { run in
            let name: String?
            if let cached = namesByAutomationID[run.automationID] {
                name = cached
            } else {
                let resolved = try store.automation(id: run.automationID)?.name
                if let resolved { namesByAutomationID[run.automationID] = resolved }
                name = resolved
            }
            return TerminalServiceAutomationRunSummary(
                run, automationName: name, workspaceID: workspaceIDsByRunID[run.id], attributedAgents: attributedAgentsByRunID[run.id] ?? [])
        }
    }

    /// Maps the neutral orchestration row the daemon builds to its Device API wire shape.
    static func deviceAgentSessionRow(_ row: TerminalServiceAgentSessionRow) -> SpacesDeviceAgentSessionRow {
        SpacesDeviceAgentSessionRow(
            id: row.id, terminalSessionID: row.terminalSessionID, agent: row.agent, label: row.label, status: row.status, note: row.note,
            projectID: row.projectID, projectName: row.projectName, workspaceID: row.workspaceID, workspaceName: row.workspaceName,
            workspaceDir: row.workspaceDir, branch: row.branch, updatedAt: row.updatedAt, lastSignalAt: row.lastSignalAt)
    }

    private func refreshedMutationResponse(
        context: RequestContext, message: String, projectID: String? = nil, workspaceID: String? = nil, sessionID: String? = nil,
        launchedTerminalSession: SpacesDeviceTerminalSessionSummary? = nil, notice: String? = nil, terminatedTerminalSession: Bool? = nil
    ) throws -> SpacesDeviceAPIResponse {
        SpacesDeviceAPIResponse(
            ok: true, message: message,
            result: .mutation(
                SpacesDeviceMutationResult(
                    overview: try loadOverview(store: context.store()), projectID: projectID, workspaceID: workspaceID, sessionID: sessionID,
                    launchedTerminalSession: launchedTerminalSession, notice: notice, terminatedTerminalSession: terminatedTerminalSession)))
    }

    /// Carries the launched terminal's own metadata in the start-command mutation response so the
    /// client can still open that session even if it exits before the refreshed overview is built and
    /// therefore never appears in `overview.sessions`.
    private func launchedTerminalSessionSummary(_ session: TerminalServiceSessionSummary, workspaceID: String) throws
        -> SpacesDeviceTerminalSessionSummary
    {
        guard let launch = session.launchConfiguration else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Launched terminal session is missing its launch configuration."])
        }
        let runtime = session.runtimeState
        let state = runtime?.state ?? session.state
        let isInteractive = state.isInteractive
        return SpacesDeviceTerminalSessionSummary(
            id: session.id, title: session.title, liveTitle: runtime?.title, workingDirectory: session.workingDirectory, shell: launch.shell,
            command: launch.command, state: state, backend: session.backend, lifetimePolicy: session.lifetimePolicy, servicePID: session.servicePID,
            childPID: session.childPID, workspaceID: workspaceID, workspaceTitle: nil, projectID: nil, projectName: nil, createdAt: launch.createdAt,
            updatedAt: runtime?.updatedAt ?? launch.createdAt, isControlAvailable: isInteractive, isSubscriptionAvailable: isInteractive,
            attachmentSnapshot: session.attachmentSnapshot ?? .init(), rowKind: .liveSession, rowSourceID: nil,
            hasFinalRender: session.hasFinalRender, foregroundDetectedAgentKind: runtime?.foregroundDetectedAgentKind?.rawValue,
            foregroundCommand: TerminalForegroundProcessInspector.displayCommand(
                executableName: runtime?.foregroundExecutableName, argv: runtime?.foregroundArgv), bellAt: runtime?.bellAt,
            bracketedPasteActive: runtime?.bracketedPasteActive ?? false)
    }

    private func resolvedRunningProcessID(request: SpacesDeviceWorkspaceProcessMutationRequest, store: SQLiteStore) throws -> String {
        let workspaceID = request.workspaceID
        if let processID = normalizedString(request.processID) { return processID }
        if let processTemplateID = normalizedString(request.processTemplateID),
            let process = try store.runningProcesses(workspaceID: workspaceID).first(where: { $0.templateID == processTemplateID })
        {
            return process.id
        }
        guard let processKey = normalizedString(request.processKey) else {
            throw NSError(domain: "SpacesDeviceAPIServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing process ID."])
        }
        let normalizedProcessKey = normalizedRowKey(processKey)
        guard
            let process = try store.runningProcesses(workspaceID: workspaceID).first(where: {
                normalizedRowKey($0.templateName) == normalizedProcessKey
            })
        else { throw NSError(domain: "SpacesDeviceAPIServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Running process not found."]) }
        return process.id
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func normalizedRowKey(_ value: String?) -> String { normalizedString(value)?.lowercased() ?? "" }

    private func workspacePort(_ port: SpacesDeviceServiceDefinition) -> ServiceDefinition { ServiceDefinition(id: port.id, name: port.name) }

    private func workspaceProcess(_ process: SpacesDeviceProcessTemplate) -> ProcessTemplate {
        ProcessTemplate(
            id: process.id, name: process.name, command: process.command, kind: process.kind,
            onExit: ProcessExitAction(rawValue: process.onExit) ?? .none)
    }

    private func workspaceBrowserSession(_ session: SpacesDeviceBrowserSession) -> BrowserSession {
        BrowserSession(name: session.name, url: session.url)
    }

    private func applyProjectConfig(_ source: SpacesDeviceProjectConfig, to project: inout ProjectRecord) {
        project.setupScript = normalizedOptionalString(source.setupScript)
        project.stopScript = normalizedOptionalString(source.stopScript)
        project.ports = source.ports.map(workspacePort)
        project.processes = source.processes.map(workspaceProcess)
        project.browserSessions = source.browserSessions.map(workspaceBrowserSession)
    }

    private func handleStateRequest(_ request: SpacesDeviceTerminalSessionRequest) throws -> SpacesDeviceAPIResponse {
        let sessionID = request.sessionID
        let startedAt = Date()
        let payload = try loadCurrentState(sessionID: sessionID)
        TerminalPerformance.logMetric(
            "device_api_state", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
        return SpacesDeviceAPIResponse(ok: true, message: "Loaded terminal state.", result: .terminalState(payload))
    }

    private func handleResolveTerminalLinkRequest(_ request: SpacesDeviceTerminalLinkResolveRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let sessionID = request.sessionID
        pruneTerminalLinkTransferAuthorizations(now: Date())
        do { return try resolveTerminalLink(request, context: context, sessionID: sessionID) } catch {
            // The raw link is the only evidence of what a client actually asked to open. A client that
            // reconstructs a link from a partial view of the terminal sends a value the user never saw,
            // and without this line the failure is indistinguishable from a genuinely missing file (#492).
            FileHandle.standardError.write(
                Data("spacesd: terminal link resolve failed session=\(sessionID) error=\(error) link=\(request.terminalLink)\n".utf8))
            throw error
        }
    }

    private func resolveTerminalLink(_ request: SpacesDeviceTerminalLinkResolveRequest, context: RequestContext, sessionID: String) throws
        -> SpacesDeviceAPIResponse
    {
        let metadata: SpacesDeviceTerminalLinkMetadata
        if canResolveTerminalLinkWithoutLocalState(request.terminalLink) {
            // Non-file links resolve without workspace roots, so this path opens no store.
            metadata = try SpacesDeviceTerminalLinkResolver.resolve(
                sessionID: sessionID, link: request.terminalLink, workingDirectory: nil, workspaceRoots: [])
        } else {
            let workspaceRoots = try loadWorkspaceRoots(store: context.store())
            // Absolute, tilde, and file:// links never anchor against a working directory, so only look
            // one up (which requires reading the session's launch/runtime state) when the resolver could
            // actually need it. Otherwise those links keep resolving even if that state is unavailable.
            let workingDirectory =
                try SpacesDeviceTerminalLinkResolver.requiresWorkingDirectory(link: request.terminalLink)
                ? terminalWorkingDirectory(sessionID: sessionID) : nil
            metadata = try SpacesDeviceTerminalLinkResolver.resolve(
                sessionID: sessionID, link: request.terminalLink, workingDirectory: workingDirectory, workspaceRoots: workspaceRoots)
        }
        if metadata.source == .localFile {
            let resolvedPath = try SpacesDeviceTerminalLinkResolver.resolvedLocalFilePath(linkID: metadata.id)
            authorizeTerminalLinkTransfer(linkID: metadata.id, sessionID: sessionID, resolvedPath: resolvedPath, now: Date())
        }
        return SpacesDeviceAPIResponse(ok: true, message: "Resolved terminal link.", result: .terminalLinkMetadata(metadata))
    }

    private func handleReadTerminalLinkChunkRequest(_ request: SpacesDeviceTerminalLinkChunkRequest) throws -> SpacesDeviceAPIResponse {
        let sessionID = request.sessionID
        let linkID = request.terminalLinkID
        guard let authorization = try terminalLinkTransferAuthorization(linkID: linkID, sessionID: sessionID, now: Date()) else {
            throw SpacesDeviceTerminalLinkResolverError.invalidLinkID
        }
        let chunk = try SpacesDeviceTerminalLinkResolver.readChunk(
            sessionID: sessionID, linkID: linkID, offset: request.offset, limit: request.limit, workspaceRoots: [authorization.resolvedPath])
        authorizeTerminalLinkTransfer(linkID: linkID, sessionID: sessionID, resolvedPath: authorization.resolvedPath, now: Date())
        return SpacesDeviceAPIResponse(ok: true, message: "Read terminal link chunk.", result: .terminalLinkChunk(chunk))
    }

    private func authorizeTerminalLinkTransfer(linkID: String, sessionID: String, resolvedPath: String, now: Date) {
        terminalLinkTransferAuthorizations[linkID] = TerminalLinkTransferAuthorization(
            sessionID: sessionID, resolvedPath: resolvedPath, expiresAt: now.addingTimeInterval(terminalLinkTransferAuthorizationTTL))
    }

    private func terminalLinkTransferAuthorization(linkID: String, sessionID: String, now: Date) throws -> TerminalLinkTransferAuthorization? {
        pruneTerminalLinkTransferAuthorizations(now: now)
        guard let authorization = terminalLinkTransferAuthorizations[linkID] else { return nil }
        guard authorization.sessionID == sessionID else { throw SpacesDeviceTerminalLinkResolverError.sessionMismatch }
        return authorization
    }

    private func pruneTerminalLinkTransferAuthorizations(now: Date) {
        terminalLinkTransferAuthorizations = terminalLinkTransferAuthorizations.filter { $0.value.expiresAt > now }
    }

    private func canResolveTerminalLinkWithoutLocalState(_ value: String?) -> Bool {
        guard let link = normalizedString(value), let scheme = URL(string: link)?.scheme?.lowercased() else { return false }
        return scheme != "file"
    }

    private func terminalWorkingDirectory(sessionID: String) throws -> String {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        // Prefer the live cwd of the session's foreground process (falling back to its child shell).
        // The tracked runtime-state working directory only advances when the shell reports a new PWD
        // through Ghostty shell integration (OSC 7), which many shells never emit — so it is stale
        // after a plain `cd`. The owning process's real cwd is always current, anchoring relative
        // links (e.g. `./statement.pdf`) in the directory the shell is actually sitting in.
        if let liveWorkingDirectory = normalizedString(Self.liveTerminalWorkingDirectory(runtimeState: runtimeState)) { return liveWorkingDirectory }
        if let workingDirectory = normalizedString(runtimeState?.workingDirectory) { return workingDirectory }
        return try TerminalSessionPersistence.readLaunchConfiguration(paths: paths).workingDirectory
    }

    private static func liveTerminalWorkingDirectory(runtimeState: TerminalSessionRuntimeState?) -> String? {
        guard let runtimeState else { return nil }
        if let foregroundPID = runtimeState.foregroundPID, let cwd = TerminalForegroundProcessInspector.workingDirectory(pid: foregroundPID) {
            return cwd
        }
        if let childPID = runtimeState.childPID, let cwd = TerminalForegroundProcessInspector.workingDirectory(pid: childPID) { return cwd }
        return nil
    }

    private func loadWorkspaceRoots(store: SQLiteStore) throws -> [String] {
        let projects = try store.projects()
        var roots = Set(projects.map(\.dir))
        for project in projects {
            let workspaces = try store.workspaces(projectID: project.id)
            roots.formUnion(workspaces.map(\.dir))
        }
        return Array(roots)
    }

    #if os(Linux) && canImport(OpenSSL)
        private func prepareLinuxSubscribe(_ request: SpacesDeviceAPIRequest) throws -> LinuxSubscribeAction {
            if request.command.isDeviceOverviewSubscription {
                // Relay the device-overview producer socket (no terminal session,
                // no control heartbeat); the producer pushes the current overview
                // on connect and a fresh one on every database change.
                return .relay(
                    LinuxSubscription(
                        sessionID: "device-overview", installationID: request.clientApp?.installationID ?? "",
                        subscriptionSocketPath: try TerminalServicePaths.deviceOverviewSocketPath(), controlSocketPath: "", clientID: nil))
            }
            if let scopePayload = request.command.workspaceDiffSignatureScope {
                // Same shape as the device-overview relay above, but the producer socket is per (workspace,
                // ref) scope and created (or subscriber-counted) on demand; see
                // `addWorkspaceDiffSignatureSubscriber`. `relayLinuxSubscription` releases the subscriber
                // slot once this relay loop returns.
                let scope = WorkspaceDiffScope(
                    workspaceID: scopePayload.workspaceID, refName: scopePayload.refName, lastCommit: scopePayload.lastCommit)
                // A thrown error here would propagate out of `handleClient` uncaught (its only catch just
                // traces and drops the connection, unlike the macOS `NWConnection` path's `finishRequest`),
                // so refuse via `.response(...)` the same way the other validation failures below do,
                // instead of `try`ing straight into `assertWorkspaceDiffScopeIsGitRepository` or
                // `addWorkspaceDiffSignatureSubscriber`. Both calls share this one do/catch: a git-repository
                // refusal and a producer-socket setup failure (path occupied, bind/unlink error) are both
                // ordinary request-level failures the client should see as a typed response, not a dropped
                // connection that reads as a transport outage on an otherwise healthy daemon.
                let socketPath: String
                do {
                    try assertWorkspaceDiffSignatureScopeIsUnambiguous(refName: scopePayload.refName, lastCommit: scopePayload.lastCommit)
                    try assertWorkspaceDiffScopeIsGitRepository(scope: scope)
                    socketPath = try addWorkspaceDiffSignatureSubscriber(scope: scope)
                } catch { return .response(SpacesDeviceAPIServer.failureResponse(for: error)) }
                return .relay(
                    LinuxSubscription(
                        sessionID: "workspace-diff-signature:\(scope.workspaceID):\(scope.lastCommit ? "last-commit" : (scope.refName ?? ""))",
                        installationID: request.clientApp?.installationID ?? "", subscriptionSocketPath: socketPath, controlSocketPath: "",
                        clientID: nil, diffSignatureScope: scope))
            }
            if let scopePayload = request.command.workspaceFileSignatureScope {
                // Same shape as the diff-signature relay above, substituting the file-scope validation
                // (`assertWorkspaceFileScopeIsValid`, no git-repository requirement) and scope/subscriber
                // registration.
                let scope = WorkspaceFileScope(workspaceID: scopePayload.workspaceID, path: scopePayload.path)
                let socketPath: String
                do {
                    try assertWorkspaceFileScopeIsValid(scope: scope)
                    socketPath = try addWorkspaceFileSignatureSubscriber(scope: scope)
                } catch { return .response(SpacesDeviceAPIServer.failureResponse(for: error)) }
                return .relay(
                    LinuxSubscription(
                        sessionID: "workspace-file-signature:\(scope.workspaceID):\(scope.path)",
                        installationID: request.clientApp?.installationID ?? "", subscriptionSocketPath: socketPath, controlSocketPath: "",
                        clientID: nil, fileSignatureScope: scope))
            }
            if let workspaceID = request.command.workspaceFileListSignatureWorkspaceID {
                let socketPath: String
                do {
                    try assertWorkspaceExistsForFileListSignature(workspaceID: workspaceID)
                    socketPath = try addWorkspaceFileListSignatureSubscriber(workspaceID: workspaceID)
                } catch { return .response(SpacesDeviceAPIServer.failureResponse(for: error)) }
                return .relay(
                    LinuxSubscription(
                        sessionID: "workspace-file-list-signature:\(workspaceID)", installationID: request.clientApp?.installationID ?? "",
                        subscriptionSocketPath: socketPath, controlSocketPath: "", clientID: nil, fileListSignatureWorkspaceID: workspaceID))
            }
            guard let sessionID = request.sessionID else {
                return .response(SpacesDeviceAPIResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument))
            }
            guard let installationID = request.clientApp?.installationID.trimmingCharacters(in: .whitespacesAndNewlines), !installationID.isEmpty
            else { return .response(SpacesDeviceAPIResponse(ok: false, message: "Missing client installation ID.", errorCode: .invalidArgument)) }
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
                let payload =
                    (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))
                    ?? (try? endedStatePayload(sessionID: sessionID, paths: paths, runtimeState: runtimeState))
                if let payload { return .finalPayload(payload) }
                return .response(
                    SpacesDeviceAPIResponse(
                        ok: false, message: "Terminal session '\(sessionID)' has no final state.", errorCode: .sessionNotAvailable))
            }
            guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
                return .response(
                    SpacesDeviceAPIResponse(
                        ok: false, message: "Terminal session '\(sessionID)' has no live state stream.", errorCode: .sessionNotAvailable))
            }
            return .relay(
                LinuxSubscription(
                    sessionID: sessionID, installationID: installationID, subscriptionSocketPath: paths.subscriptionSocketPath,
                    controlSocketPath: paths.controlSocketPath, clientID: request.clientID))
        }

        private func relayLinuxSubscription(_ subscription: LinuxSubscription, ssl: OpaquePointer) throws {
            // Placed first (ahead of the connect below, which can itself throw) so a workspace-diff-signature
            // subscriber slot taken in `prepareLinuxSubscribe` is always released once this relay ends,
            // regardless of where it ends. There is no explicit unsubscribe command; this relay loop
            // returning (EOF, error, or an early throw) is what "unsubscribe" means.
            defer {
                if let scope = subscription.diffSignatureScope { performOnQueue { self.removeWorkspaceDiffSignatureSubscriber(scope: scope) } }
                if let scope = subscription.fileSignatureScope { performOnQueue { self.removeWorkspaceFileSignatureSubscriber(scope: scope) } }
                if let workspaceID = subscription.fileListSignatureWorkspaceID {
                    performOnQueue { self.removeWorkspaceFileListSignatureSubscriber(workspaceID: workspaceID) }
                }
            }
            let relaySocketFD = try connectUnixSocket(path: subscription.subscriptionSocketPath)
            defer {
                Self.shutdownSocket(relaySocketFD, how: Self.shutdownReadWrite)
                close(relaySocketFD)
            }

            let heartbeatTimer: DispatchSourceTimer?
            if let clientID = subscription.clientID {
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                timer.schedule(deadline: .now() + .seconds(20), repeating: .seconds(20))
                timer.setEventHandler { [controlSocketPath = subscription.controlSocketPath] in
                    _ = try? TerminalControlClient.send(
                        request: TerminalControlRequest(command: .heartbeat(TerminalControlClientPayload(clientID: clientID))),
                        socketPath: controlSocketPath)
                }
                heartbeatTimer = timer
                timer.resume()
            } else {
                heartbeatTimer = nil
            }
            defer { heartbeatTimer?.cancel() }

            let startedAt = Date()
            let performanceLoggingEnabled = SpacesDeviceTerminalPerformanceLogger.isEnabled()
            var buffer = [UInt8](repeating: 0, count: Self.streamRelayReadBufferSize)
            while true {
                let count = read(relaySocketFD, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try buffer.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    let data = Data(bytes: baseAddress, count: count)
                    let attributes = performanceLoggingEnabled ? deviceAPIStreamRelayAttributes(for: data) : [:]
                    let writeStartedAt = performanceLoggingEnabled ? Date() : nil
                    if performanceLoggingEnabled {
                        logDeviceAPIPerformance(
                            sessionID: subscription.sessionID, name: "stream_relay_read",
                            emittedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds, count: count, attributes: attributes)
                        logDeviceAPIPerformance(
                            sessionID: subscription.sessionID, name: "stream_network_send_begin", count: count, attributes: attributes)
                    }
                    try LinuxServer.writeTLSResponse(data, ssl: ssl)
                    if let writeStartedAt {
                        logDeviceAPIPerformance(
                            sessionID: subscription.sessionID, name: "stream_network_send_end",
                            elapsedMS: TerminalPerformance.elapsedMS(since: writeStartedAt), count: count, attributes: attributes)
                    }
                }
            }
            TerminalPerformance.logMetric(
                "device_api_subscribe", target: "session=\(subscription.sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                success: true)
        }

        enum LinuxServiceTunnelOutcome {
            case reject(SpacesDeviceAPIResponse)
            case ready(loopbackFD: Int32)
        }

        /// Authorizes and reserves a concurrent-tunnel cap slot on the server queue (mirroring the
        /// subscription prepare path), then resolves and dials on the calling per-client thread so the
        /// dial's connect timeout (up to 2 seconds for a configured-but-dead service) never stalls the
        /// shared server queue. A rejection after the reservation releases the slot internally; the
        /// caller must pair `.ready` with `finishServiceTunnel()` once the splice returns.
        func prepareServiceTunnel(_ request: SpacesDeviceAPIRequest, tunnelRequest: SpacesDeviceServiceTunnelRequest) -> LinuxServiceTunnelOutcome {
            // nil means the cap slot was reserved; non-nil is an early rejection issued before reserving.
            let earlyRejection: LinuxServiceTunnelOutcome?
            do {
                earlyRejection = try syncOnQueue { () -> LinuxServiceTunnelOutcome? in
                    try self.admitOnQueue()
                    try self.authorize(request)
                    guard let installationID = request.clientApp?.installationID.trimmingCharacters(in: .whitespacesAndNewlines),
                        !installationID.isEmpty
                    else {
                        return LinuxServiceTunnelOutcome.reject(
                            SpacesDeviceAPIResponse(ok: false, message: "Missing client installation ID.", errorCode: .invalidArgument))
                    }
                    guard self.activeServiceTunnelCount < Self.maxConcurrentServiceTunnels else {
                        return LinuxServiceTunnelOutcome.reject(
                            SpacesDeviceAPIResponse(ok: false, message: "Too many concurrent service tunnels.", errorCode: .busy))
                    }
                    self.activeServiceTunnelCount += 1
                    return nil
                }
            } catch { return .reject(Self.failureResponse(for: error)) }
            if let earlyRejection { return earlyRejection }

            do {
                switch try SpacesDeviceServiceTunnelResolver.resolve(tunnelRequest) {
                case .failure(let message, let errorCode):
                    finishServiceTunnel()
                    return .reject(SpacesDeviceAPIResponse(ok: false, message: message, errorCode: errorCode))
                case .port(let port):
                    do { return .ready(loopbackFD: try SpacesDeviceServiceTunnelDialer.dialLoopback(port: port, blocking: false)) } catch {
                        trace("tunnel_dial_failed service=\(tunnelRequest.serviceName) port=\(port) error=\(error)")
                        finishServiceTunnel()
                        return .reject(
                            SpacesDeviceAPIResponse(
                                ok: false, message: "Service '\(tunnelRequest.serviceName)' is not accepting connections.",
                                errorCode: .serviceNotRunning))
                    }
                }
            } catch {
                finishServiceTunnel()
                return .reject(Self.failureResponse(for: error))
            }
        }

        func finishServiceTunnel() { performOnQueue { self.activeServiceTunnelCount = max(0, self.activeServiceTunnelCount - 1) } }

    #endif

    #if canImport(Network) && canImport(Security)
        private func handleSubscribeRequest(_ request: SpacesDeviceAPIRequest, connection: NWConnection) throws {
            if request.command.isDeviceOverviewSubscription {
                try relayOverviewSubscription(connection: connection, installationID: request.clientApp?.installationID ?? "")
                return
            }
            if let scopePayload = request.command.workspaceDiffSignatureScope {
                // Thrown here propagates out to `processBufferedLines`'s enclosing `do`/`catch`, which
                // converts it to a typed `failureResponse` and sends that to the client before closing the
                // connection — the same path every other `try server.handle...Request` failure on this
                // connection takes, so this does not need its own response-shaping.
                try assertWorkspaceDiffSignatureScopeIsUnambiguous(refName: scopePayload.refName, lastCommit: scopePayload.lastCommit)
                try relayWorkspaceDiffSignatureSubscription(
                    connection: connection,
                    scope: WorkspaceDiffScope(
                        workspaceID: scopePayload.workspaceID, refName: scopePayload.refName, lastCommit: scopePayload.lastCommit),
                    installationID: request.clientApp?.installationID ?? "")
                return
            }
            if let scopePayload = request.command.workspaceFileSignatureScope {
                try relayWorkspaceFileSignatureSubscription(
                    connection: connection, scope: WorkspaceFileScope(workspaceID: scopePayload.workspaceID, path: scopePayload.path),
                    installationID: request.clientApp?.installationID ?? "")
                return
            }
            if let workspaceID = request.command.workspaceFileListSignatureWorkspaceID {
                try relayWorkspaceFileListSignatureSubscription(
                    connection: connection, workspaceID: workspaceID, installationID: request.clientApp?.installationID ?? "")
                return
            }
            guard let sessionID = request.sessionID else {
                sendResponse(SpacesDeviceAPIResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument), to: connection) { _ in
                    connection.cancel()
                }
                return
            }
            guard let installationID = request.clientApp?.installationID.trimmingCharacters(in: .whitespacesAndNewlines), !installationID.isEmpty
            else {
                sendResponse(
                    SpacesDeviceAPIResponse(ok: false, message: "Missing client installation ID.", errorCode: .invalidArgument), to: connection
                ) { _ in connection.cancel() }
                return
            }
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
                let payload =
                    (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))
                    ?? (try? endedStatePayload(sessionID: sessionID, paths: paths, runtimeState: runtimeState))
                if let payload {
                    sendStreamPayloadAndComplete(payload, sessionID: sessionID, to: connection)
                } else {
                    sendResponse(
                        SpacesDeviceAPIResponse(
                            ok: false, message: "Terminal session '\(sessionID)' has no final state.", errorCode: .sessionNotAvailable),
                        to: connection
                    ) { _ in connection.cancel() }
                }
                return
            }
            guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
                sendResponse(
                    SpacesDeviceAPIResponse(
                        ok: false, message: "Terminal session '\(sessionID)' has no live state stream.", errorCode: .sessionNotAvailable),
                    to: connection
                ) { _ in connection.cancel() }
                return
            }

            let startedAt = Date()
            let relaySocketFD = try connectUnixSocket(path: paths.subscriptionSocketPath)
            try setNonBlocking(relaySocketFD)

            let relayQueue = DispatchQueue(label: "spaces.device.api.stream.\(sessionID).\(ObjectIdentifier(connection))")
            let relaySource = DispatchSource.makeReadSource(fileDescriptor: relaySocketFD, queue: relayQueue)
            relaySource.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.relayStateData(from: relaySocketFD, to: connection)
            }
            relaySource.setCancelHandler { close(relaySocketFD) }

            let heartbeatTimer: DispatchSourceTimer?
            if let clientID = request.clientID {
                let timer = DispatchSource.makeTimerSource(queue: relayQueue)
                timer.schedule(deadline: .now() + .seconds(20), repeating: .seconds(20))
                timer.setEventHandler {
                    _ = try? TerminalControlClient.send(
                        request: TerminalControlRequest(command: .heartbeat(TerminalControlClientPayload(clientID: clientID))),
                        socketPath: paths.controlSocketPath)
                }
                heartbeatTimer = timer
            } else {
                heartbeatTimer = nil
            }

            streamRelays[ObjectIdentifier(connection)] = StreamRelay(
                sessionID: sessionID, installationID: installationID, relaySocketFD: relaySocketFD, relayQueue: relayQueue, relaySource: relaySource,
                heartbeatTimer: heartbeatTimer, connection: connection, sendSequencer: StreamSendSequencer(queueKey: queueKey))

            relaySource.resume()
            heartbeatTimer?.resume()

            TerminalPerformance.logMetric(
                "device_api_subscribe", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
        }

        /// Relays the device-overview producer socket to a subscribing connection,
        /// reusing the same stream-relay machinery as terminal subscriptions (no
        /// terminal heartbeat). The producer sends the current overview on connect
        /// and a fresh one on every database change.
        private func relayOverviewSubscription(connection: NWConnection, installationID: String) throws {
            let socketPath = try TerminalServicePaths.deviceOverviewSocketPath()
            let relaySocketFD = try connectUnixSocket(path: socketPath)
            try setNonBlocking(relaySocketFD)
            let relayQueue = DispatchQueue(label: "spaces.device.api.overview.\(ObjectIdentifier(connection))")
            let relaySource = DispatchSource.makeReadSource(fileDescriptor: relaySocketFD, queue: relayQueue)
            relaySource.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.relayStateData(from: relaySocketFD, to: connection)
            }
            relaySource.setCancelHandler { close(relaySocketFD) }
            streamRelays[ObjectIdentifier(connection)] = StreamRelay(
                sessionID: "device-overview", installationID: installationID, relaySocketFD: relaySocketFD, relayQueue: relayQueue,
                relaySource: relaySource, heartbeatTimer: nil, connection: connection, sendSequencer: StreamSendSequencer(queueKey: queueKey))
            relaySource.resume()
        }

        /// Relays one (workspace, ref) scope's diff-signature producer socket to a subscribing connection,
        /// reusing the same stream-relay machinery as the device-overview and terminal-session relays
        /// above. Takes a subscriber slot for `scope` (creating its producer + poll timer on the first
        /// subscriber) before connecting; `closeStreamRelay` releases that slot once this relay's connection
        /// closes, using the scope recorded on the `StreamRelay`. There is no explicit unsubscribe command,
        /// so the connection closing (client disconnect, revoke, or daemon stop) is the only unsubscribe.
        private func relayWorkspaceDiffSignatureSubscription(connection: NWConnection, scope: WorkspaceDiffScope, installationID: String) throws {
            // Refuse before taking a subscriber slot: a non-git workspace's poll loop would otherwise sit
            // silently producing nothing, leaving the client to read "unavailable" forever instead of the
            // same typed refusal `workspaceDiffManifestChunk` gives for the same case.
            try assertWorkspaceDiffScopeIsGitRepository(scope: scope)
            let socketPath = try addWorkspaceDiffSignatureSubscriber(scope: scope)
            do {
                let relaySocketFD = try connectUnixSocket(path: socketPath)
                try setNonBlocking(relaySocketFD)
                let relayQueue = DispatchQueue(label: "spaces.device.api.workspace-diff.\(ObjectIdentifier(connection))")
                let relaySource = DispatchSource.makeReadSource(fileDescriptor: relaySocketFD, queue: relayQueue)
                relaySource.setEventHandler { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.relayStateData(from: relaySocketFD, to: connection)
                }
                relaySource.setCancelHandler { close(relaySocketFD) }
                streamRelays[ObjectIdentifier(connection)] = StreamRelay(
                    sessionID: "workspace-diff-signature:\(scope.workspaceID):\(scope.lastCommit ? "last-commit" : (scope.refName ?? ""))",
                    installationID: installationID, relaySocketFD: relaySocketFD, relayQueue: relayQueue, relaySource: relaySource,
                    heartbeatTimer: nil, connection: connection, sendSequencer: StreamSendSequencer(queueKey: queueKey), diffSignatureScope: scope)
                relaySource.resume()
            } catch {
                // The relay never made it into `streamRelays`, so `closeStreamRelay` will never see this
                // subscriber's scope and release its slot; release it here instead.
                removeWorkspaceDiffSignatureSubscriber(scope: scope)
                throw error
            }
        }

        /// Relays one (workspace, path) scope's file-signature producer socket to a subscribing connection.
        /// Mirrors `relayWorkspaceDiffSignatureSubscription` exactly, substituting the file-scope validation
        /// (`assertWorkspaceFileScopeIsValid`, which has no git-repository requirement — see its doc comment)
        /// and subscriber/scope types.
        private func relayWorkspaceFileSignatureSubscription(connection: NWConnection, scope: WorkspaceFileScope, installationID: String) throws {
            try assertWorkspaceFileScopeIsValid(scope: scope)
            let socketPath = try addWorkspaceFileSignatureSubscriber(scope: scope)
            do {
                let relaySocketFD = try connectUnixSocket(path: socketPath)
                try setNonBlocking(relaySocketFD)
                let relayQueue = DispatchQueue(label: "spaces.device.api.workspace-file.\(ObjectIdentifier(connection))")
                let relaySource = DispatchSource.makeReadSource(fileDescriptor: relaySocketFD, queue: relayQueue)
                relaySource.setEventHandler { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.relayStateData(from: relaySocketFD, to: connection)
                }
                relaySource.setCancelHandler { close(relaySocketFD) }
                streamRelays[ObjectIdentifier(connection)] = StreamRelay(
                    sessionID: "workspace-file-signature:\(scope.workspaceID):\(scope.path)", installationID: installationID,
                    relaySocketFD: relaySocketFD, relayQueue: relayQueue, relaySource: relaySource, heartbeatTimer: nil, connection: connection,
                    sendSequencer: StreamSendSequencer(queueKey: queueKey), fileSignatureScope: scope)
                relaySource.resume()
            } catch {
                // The relay never made it into `streamRelays`, so `closeStreamRelay` will never see this
                // subscriber's scope and release its slot; release it here instead.
                removeWorkspaceFileSignatureSubscriber(scope: scope)
                throw error
            }
        }

        private func relayWorkspaceFileListSignatureSubscription(connection: NWConnection, workspaceID: String, installationID: String) throws {
            try assertWorkspaceExistsForFileListSignature(workspaceID: workspaceID)
            let socketPath = try addWorkspaceFileListSignatureSubscriber(workspaceID: workspaceID)
            do {
                let relaySocketFD = try connectUnixSocket(path: socketPath)
                try setNonBlocking(relaySocketFD)
                let relayQueue = DispatchQueue(label: "spaces.device.api.workspace-file-list.\(ObjectIdentifier(connection))")
                let relaySource = DispatchSource.makeReadSource(fileDescriptor: relaySocketFD, queue: relayQueue)
                relaySource.setEventHandler { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.relayStateData(from: relaySocketFD, to: connection)
                }
                relaySource.setCancelHandler { close(relaySocketFD) }
                streamRelays[ObjectIdentifier(connection)] = StreamRelay(
                    sessionID: "workspace-file-list-signature:\(workspaceID)", installationID: installationID, relaySocketFD: relaySocketFD,
                    relayQueue: relayQueue, relaySource: relaySource, heartbeatTimer: nil, connection: connection,
                    sendSequencer: StreamSendSequencer(queueKey: queueKey), fileListSignatureWorkspaceID: workspaceID)
                relaySource.resume()
            } catch {
                removeWorkspaceFileListSignatureSubscriber(workspaceID: workspaceID)
                throw error
            }
        }

    #endif

    #if canImport(Network) && canImport(Security)
        private func sendStreamPayloadAndComplete(_ payload: GhosttyRemoteSessionStatePayload, sessionID: String, to connection: NWConnection) {
            do {
                let data = try GhosttyRemoteSessionStateCodec.encodeLine(payload)
                let attributes = deviceAPIStreamRelayAttributes(for: data)
                logDeviceAPIPerformance(sessionID: sessionID, name: "stream_relay_read", count: data.count, attributes: attributes)
                networkShaper.send(
                    content: data, to: connection, on: queue,
                    onSendBegin: { [weak self, sessionID, attributes, count = data.count] in
                        self?.logDeviceAPIPerformance(sessionID: sessionID, name: "stream_network_send_begin", count: count, attributes: attributes)
                    }, isComplete: true
                ) { [weak self, weak connection] error in
                    if let error {
                        self?.trace("stream_final_payload_send_error session=\(sessionID) error=\(error)")
                        connection?.cancel()
                    } else {
                        connection?.cancel()
                    }
                }
            } catch {
                sendResponse(
                    SpacesDeviceAPIResponse(ok: false, message: String(describing: error), errorCode: SpacesDeviceAPIServer.errorCode(for: error)),
                    to: connection
                ) { _ in connection.cancel() }
            }
        }

        private func relayStateData(from relaySocketFD: Int32, to connection: NWConnection) {
            var buffer = [UInt8](repeating: 0, count: Self.streamRelayReadBufferSize)
            var relayedData = Data()
            var firstReadUptimeNanoseconds: UInt64?
            while true {
                let count = read(relaySocketFD, &buffer, buffer.count)
                if count == 0 {
                    if !relayedData.isEmpty {
                        enqueueRelayedStateData(
                            relayedData, firstReadUptimeNanoseconds: firstReadUptimeNanoseconds, to: connection, closeAfterSend: true)
                    } else {
                        queue.async { [weak self, weak connection] in
                            guard let self, let connection else { return }
                            self.closeStreamRelayAfterQueuedSendsDrain(connection: connection)
                        }
                    }
                    return
                }
                if count < 0 {
                    if errno == EWOULDBLOCK || errno == EAGAIN {
                        if !relayedData.isEmpty {
                            enqueueRelayedStateData(relayedData, firstReadUptimeNanoseconds: firstReadUptimeNanoseconds, to: connection)
                        }
                        return
                    }
                    queue.async { [weak self, weak connection] in
                        guard let self, let connection else { return }
                        self.closeStreamRelayUnlessFinalSendPending(connection: connection)
                    }
                    return
                }
                firstReadUptimeNanoseconds = firstReadUptimeNanoseconds ?? DispatchTime.now().uptimeNanoseconds
                relayedData.append(buffer, count: count)
            }
        }

        private func enqueueRelayedStateData(
            _ data: Data, firstReadUptimeNanoseconds: UInt64?, to connection: NWConnection, closeAfterSend: Bool = false
        ) {
            queue.async { [weak self, weak connection, data, firstReadUptimeNanoseconds, closeAfterSend] in
                guard let self, let connection else { return }
                if closeAfterSend, self.prepareStreamRelayForFinalSend(connection: connection) == nil { return }
                self.sendRelayedStateData(
                    data, firstReadUptimeNanoseconds: firstReadUptimeNanoseconds, to: connection, closeAfterSend: closeAfterSend)
            }
        }

        private func prepareStreamRelayForFinalSend(connection: NWConnection) -> (relay: StreamRelay, didStartClosing: Bool)? {
            let key = ObjectIdentifier(connection)
            guard let relay = streamRelays[key] else { return nil }
            let didStartClosing = streamRelaysClosingAfterFinalSend.insert(key).inserted
            guard didStartClosing else { return (relay, false) }
            relay.heartbeatTimer?.cancel()
            relay.relaySource.cancel()
            shutdown(relay.relaySocketFD, SHUT_RDWR)
            return (relay, true)
        }

        private func sendRelayedStateData(
            _ data: Data, firstReadUptimeNanoseconds: UInt64?, to connection: NWConnection, closeAfterSend: Bool = false
        ) {
            guard let relay = streamRelays[ObjectIdentifier(connection)] else { return }
            let performanceLoggingEnabled = SpacesDeviceTerminalPerformanceLogger.isEnabled()
            let attributes = performanceLoggingEnabled ? deviceAPIStreamRelayAttributes(for: data) : [:]
            if performanceLoggingEnabled {
                logDeviceAPIPerformance(
                    sessionID: relay.sessionID, name: "stream_relay_read",
                    emittedUptimeNanoseconds: firstReadUptimeNanoseconds ?? DispatchTime.now().uptimeNanoseconds, count: data.count,
                    attributes: attributes)
            }
            relay.sendSequencer.enqueue {
                [weak self, weak connection, sessionID = relay.sessionID, attributes, data, closeAfterSend, performanceLoggingEnabled] finish in
                guard let self, let connection else {
                    finish(nil)
                    return
                }
                self.networkShaper.send(
                    content: data, to: connection, on: self.queue,
                    onSendBegin: { [weak self, sessionID, attributes, count = data.count] in
                        guard performanceLoggingEnabled else { return }
                        var sendAttributes = attributes
                        sendAttributes["network_send_bytes"] = String(count)
                        self?.logDeviceAPIPerformance(
                            sessionID: sessionID, name: "stream_network_send_begin", count: count, attributes: sendAttributes)
                    }, isComplete: closeAfterSend, applyInitialDelay: closeAfterSend, applyBandwidthDelay: closeAfterSend
                ) { [weak self, weak connection] error in
                    self?.queue.async { [weak self, weak connection] in
                        if let error {
                            self?.trace("stream_relay_send_error error=\(error)")
                            if let self, let connection { self.closeStreamRelay(connection: connection) }
                        } else if closeAfterSend, let self, let connection {
                            self.closeStreamRelay(connection: connection)
                        }
                        finish(error)
                    }
                }
            }
        }

        private func closeStreamRelay(connection: NWConnection, cancelNetworkConnection: Bool = true) {
            let key = ObjectIdentifier(connection)
            guard let relay = streamRelays.removeValue(forKey: key) else {
                streamRelaysClosingAfterFinalSend.remove(key)
                return
            }
            let relayReadSideAlreadyClosed = streamRelaysClosingAfterFinalSend.remove(key) != nil
            trace("stream_relay_close peer=\(String(describing: connection.endpoint))")
            if !relayReadSideAlreadyClosed {
                relay.heartbeatTimer?.cancel()
                relay.relaySource.cancel()
                shutdown(relay.relaySocketFD, SHUT_RDWR)
            }
            if let scope = relay.diffSignatureScope { removeWorkspaceDiffSignatureSubscriber(scope: scope) }
            if let scope = relay.fileSignatureScope { removeWorkspaceFileSignatureSubscriber(scope: scope) }
            if let workspaceID = relay.fileListSignatureWorkspaceID { removeWorkspaceFileListSignatureSubscriber(workspaceID: workspaceID) }
            if cancelNetworkConnection { connection.cancel() }
        }

        private func closeStreamRelayUnlessFinalSendPending(connection: NWConnection) {
            guard !streamRelaysClosingAfterFinalSend.contains(ObjectIdentifier(connection)) else { return }
            closeStreamRelay(connection: connection)
        }

        private func closeStreamRelayAfterQueuedSendsDrain(connection: NWConnection) {
            guard let prepared = prepareStreamRelayForFinalSend(connection: connection), prepared.didStartClosing else { return }
            prepared.relay.sendSequencer.enqueue { [weak self, weak connection] finish in
                defer { finish(nil) }
                guard let self, let connection else { return }
                self.closeStreamRelay(connection: connection)
            }
        }

        private func closeRequestConnection(connection: NWConnection) {
            requestConnections.removeValue(forKey: ObjectIdentifier(connection))
            trace("request_connection_closed active=\(requestConnections.count)")
        }

        private func closeRequestConnectionAfterNetworkUpdate(connection: NWConnection, cancelNetworkConnection: Bool) {
            performOnQueue {
                self.closeStreamRelay(connection: connection, cancelNetworkConnection: cancelNetworkConnection)
                self.teardownTunnel(connection: connection, cancelConnection: cancelNetworkConnection)
                self.closeRequestConnection(connection: connection)
            }
        }

        private func closeStreamRelaysOnQueue(forInstallationID installationID: String) {
            let normalizedID = installationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty else { return }
            let connections = streamRelays.values.filter { $0.installationID == normalizedID }.map(\.connection)
            for connection in connections { closeStreamRelay(connection: connection) }
            // A revoked installation loses its service tunnels along with its subscriptions.
            teardownTunnels(forInstallationID: normalizedID)
        }
    #elseif os(Linux) && canImport(OpenSSL)
        private func closeStreamRelaysOnQueue(forInstallationID installationID: String) {
            let normalizedID = installationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty else { return }
            linuxServer?.closeConnections(forInstallationID: normalizedID)
        }
    #endif

    private func stopOnQueue() {
        acceptingRequests = false
        stopOverviewStreamServer()
        #if canImport(Network) && canImport(Security)
            teardownAllTunnels()
            for relay in Array(streamRelays.values) { closeStreamRelay(connection: relay.connection) }
            for connection in Array(requestConnections.values.map(\.connection)) { connection.cancel() }
            requestConnections.removeAll()
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
        #elseif os(Linux) && canImport(OpenSSL)
            linuxServer?.stop()
            linuxServer = nil
        #endif
        terminalLinkTransferAuthorizations.removeAll()
        setRunning(false)
    }

    private func syncOnQueue<T>(_ work: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try work() }
        return try queue.sync(execute: work)
    }

    func performOnQueue(_ work: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { work() } else { queue.async(execute: work) }
    }

    private func connectUnixSocket(path: String) throws -> Int32 {
        let socketFD = socket(AF_UNIX, Self.streamSocketType, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try setNoSIGPIPE(socketFD)
        var address = try makeUnixSocketAddress(path: path)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }
        return socketFD
    }

    private func makeUnixSocketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8Path = path.utf8CString
        guard utf8Path.count <= maxLength else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            utf8Path.withUnsafeBufferPointer { buffer in if let baseAddress = buffer.baseAddress { memcpy(pointer, baseAddress, buffer.count) } }
        }
        return address
    }

    private func loadCurrentState(sessionID: String) throws -> GhosttyRemoteSessionStatePayload {
        // A session this daemon hosts is in this process, so read its state from the live core instead of
        // connecting to that core's own subscription socket and having it export the same frame back.
        if let livePayload = liveTerminalSessionStateProvider?(sessionID) { return livePayload }
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            if let finalState = try? TerminalSessionPersistence.readRemoteSessionState(paths: paths) { return finalState }
            return try endedStatePayload(sessionID: sessionID, paths: paths, runtimeState: runtimeState)
        }
        guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Terminal session '\(sessionID)' has no live state stream."])
        }

        let socketFD = try connectUnixSocket(path: paths.subscriptionSocketPath)
        defer {
            Self.shutdownSocket(socketFD, how: Self.shutdownReadWrite)
            close(socketFD)
        }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(socketFD, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            data.append(buffer, count: count)
            if let newlineIndex = data.firstIndex(of: 0x0A) {
                data.removeSubrange(newlineIndex..<data.endIndex)
                break
            }
        }

        guard !data.isEmpty else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Terminal session '\(sessionID)' did not return a state payload."])
        }
        return try GhosttyRemoteSessionStateCodec.decodeLine(data)
    }

    private func endedStatePayload(sessionID: String, paths: TerminalSessionPaths, runtimeState: TerminalSessionRuntimeState) throws
        -> GhosttyRemoteSessionStatePayload
    {
        let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        let attachmentSnapshot = ((try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? TerminalSessionAttachmentSnapshot())
            .liveWireProjection()
        let emittedAt = runtimeState.exitedAt ?? runtimeState.updatedAt
        return GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: emittedAt, sessionStateRevision: nil,
            sessionStateFlags: nil, screenStateRevision: nil, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
            title: runtimeState.title ?? launchConfiguration?.title ?? sessionID,
            workingDirectory: runtimeState.workingDirectory ?? launchConfiguration?.workingDirectory ?? paths.rootDirectory, outputByteCount: nil)
    }

    #if canImport(Network) && canImport(Security)
        /// `sendQueue` is where the shaper paces its chunks and where the completion is delivered when it
        /// does; it defaults to the Device API queue, and a request connection passes its own so the read
        /// loop resumes on the queue that owns its buffer.
        private func sendResponse(
            _ response: SpacesDeviceAPIResponse, to connection: NWConnection, on sendQueue: DispatchQueue? = nil,
            completion: @escaping @Sendable (Error?) -> Void
        ) {
            do {
                var data = try SpacesDeviceAPICodec.encodeResponse(response)
                data.append(0x0A)
                networkShaper.send(content: data, to: connection, on: sendQueue ?? queue, completion: completion)
            } catch { completion(error) }
        }
    #endif

    private func setNonBlocking(_ fileDescriptor: Int32) throws {
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func setNoSIGPIPE(_ fileDescriptor: Int32) throws {
        #if canImport(Darwin)
            var yes: Int32 = 1
            guard setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        #endif
    }

    #if canImport(Network) && canImport(Security)
        private static func nwPort(_ port: Int) throws -> NWEndpoint.Port {
            guard (0...65_535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw POSIXError(.EINVAL) }
            return nwPort
        }
    #endif

    private static func shutdownSocket(_ fileDescriptor: Int32, how: Int32) {
        #if canImport(Glibc)
            shutdown(fileDescriptor, how)
        #else
            shutdown(fileDescriptor, how)
        #endif
    }

    private static var streamSocketType: Int32 {
        #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }

    private static var shutdownReadWrite: Int32 {
        #if canImport(Glibc)
            Int32(SHUT_RDWR)
        #else
            SHUT_RDWR
        #endif
    }

    func trace(_ message: String) {
        guard traceEnabled else { return }
        FileHandle.standardOutput.write(Data("spaces-device-api-trace \(message)\n".utf8))
    }

    private func logDeviceAPIPerformance(
        sessionID: String, name: String, emittedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds, elapsedMS: Int? = nil,
        count: Int? = nil, attributes: [String: String] = [:]
    ) {
        SpacesDeviceTerminalPerformanceLogger.emit(
            .init(
                sessionID: sessionID, source: "device-api", name: name, emittedUptimeNanoseconds: emittedUptimeNanoseconds, elapsedMS: elapsedMS,
                count: count, attributes: attributes))
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        running = value
        listenerWaitingSince = nil
        stateLock.unlock()
    }

    /// Starts the waiting clock on the first waiting report and keeps the original timestamp for
    /// repeats, so a listener that keeps re-reporting the same wait cannot postpone the verdict.
    private func markListenerWaiting() {
        stateLock.lock()
        if listenerWaitingSince == nil { listenerWaitingSince = Date() }
        stateLock.unlock()
    }
}
