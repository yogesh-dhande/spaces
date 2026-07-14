#if os(Linux)
    import Dispatch
    import Foundation
    import Glibc
    import ghosttyvtshim
    import spacesterminalcore

    enum GhosttyLinuxHeadlessSessionError: LocalizedError {
        case vtSessionUnavailable
        case vtReplayFailed
        case snapshotUnavailable

        var errorDescription: String? {
            switch self {
            case .vtSessionUnavailable: "libghostty-vt is not available for the headless terminal session."
            case .vtReplayFailed: "libghostty-vt could not replay the terminal transcript."
            case .snapshotUnavailable: "Unable to export a headless terminal render frame."
            }
        }
    }

    /// Bridges the PTY driver's synchronous output callback to the main-actor task that
    /// persists and renders that output. Once the PTY driver has switched to handoff
    /// buffering, no delivery can register here, so draining this fence is a stable
    /// boundary before output.log is closed.
    final class GhosttyLinuxHandoffOutputDeliveryFence: @unchecked Sendable {
        private let lock = NSLock()
        private var deliveryCount = 0
        private var drainWaiters: [CheckedContinuation<Void, Never>] = []

        func beginDelivery() {
            lock.lock()
            deliveryCount += 1
            lock.unlock()
        }

        func finishDelivery() {
            lock.lock()
            precondition(deliveryCount > 0, "finishing an output delivery that was never registered")
            deliveryCount -= 1
            let waiters = deliveryCount == 0 ? drainWaiters : []
            if deliveryCount == 0 { drainWaiters.removeAll() }
            lock.unlock()
            for waiter in waiters { waiter.resume() }
        }

        func waitUntilDrained() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard deliveryCount > 0 else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                drainWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    @MainActor public final class GhosttyEmbeddedSessionCore {
        private static let maxScrollbackBytes = TerminalScrollbackBudget.defaultMaxBytes
        nonisolated static let outputReplayChunkByteCount = 1024 * 1024

        private enum RenderStateExportMode {
            case selfContained
            case streamDeltaAllowed
        }

        public let launchConfiguration: TerminalSessionLaunchConfiguration
        public let paths: TerminalSessionPaths

        private let controlQueue: DispatchQueue
        private let stateStreamQueue: DispatchQueue
        private let ptyDriver: HostManagedPTYTerminalSessionDriver
        private let outputDeliveryFence = GhosttyLinuxHandoffOutputDeliveryFence()
        private var controlServer: TerminalControlServer?
        private var stateStreamServer: GhosttyRemoteSessionStateStreamServer?
        private var outputHandle: FileHandle?
        private var outputByteCount = 0
        private nonisolated(unsafe) var vtSession: OpaquePointer?
        private var started = false
        private var terminating = false
        private var lastRuntimeState: TerminalSessionRuntimeState?
        private var lastKnownChildPID: Int32?
        private var terminalSize: (columns: Int, rows: Int) = (80, 24)
        // The Spaces theme appearance the vt session is currently themed for. The headless daemon
        // cannot read the client's OS appearance, so it defaults to dark and adopts the attaching
        // client's appearance on attach.
        private var currentAppearance: ThemeAppearance = .dark
        private var ownerEpoch: UInt64 = 0
        private var screenStateRevision: UInt64 = 0
        /// Set for the brief exec-in-place quiesce window so no late resync turn
        /// broadcasts a frame while the session is being handed to the staged daemon.
        /// Cleared on resume (`resumeFromHandoff`) or the failed-exec fallback
        /// (`resumeInPlaceAfterFailedExec`).
        private var suppressBroadcastsForHandoff = false
        /// Byte offset where renderer-disconnected output begins. Failed handoff streams
        /// this persisted suffix back through the existing VT without duplicating it.
        private var handoffTranscriptReplayOffset: UInt64?
        private var renderUpdateBaseline: GhosttyRenderUpdateBaseline?
        private var forceNextBroadcastFullRenderUpdate = false
        private var localOwnerCommandInputOutputResyncPending = false
        private var scrollDeltaNormalizer = TerminalScrollDeltaNormalizer()
        private var inputOutputResyncTask: Task<Void, Never>?
        private let onSessionClosed: (@MainActor (GhosttyEmbeddedSessionCore) -> Void)?

        public init(
            launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
            requestSurfaceRefreshAction _: (@MainActor () -> Void)? = nil, onSessionClosed: (@MainActor (GhosttyEmbeddedSessionCore) -> Void)? = nil
        ) {
            self.launchConfiguration = launchConfiguration
            self.paths = paths
            self.onSessionClosed = onSessionClosed
            controlQueue = DispatchQueue(label: "spaces.terminal.session-host.control.\(launchConfiguration.sessionID)")
            stateStreamQueue = DispatchQueue(label: "spaces.terminal.session-host.state-stream.\(launchConfiguration.sessionID)")
            ptyDriver = HostManagedPTYTerminalSessionDriver(launchConfiguration: launchConfiguration)
        }

        deinit { if let vtSession { spaces_ghostty_vt_session_free(vtSession) } }

        public func startIfNeeded() throws {
            guard !started else { return }
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            try ensureOutputHandle()
            guard let vtSession = makeVTSession(columns: terminalSize.columns, rows: terminalSize.rows) else {
                throw GhosttyLinuxHeadlessSessionError.vtSessionUnavailable
            }
            self.vtSession = vtSession
            started = true
            terminating = false
            writeRuntimeState(state: .starting)
            installOutputHandler()
            ptyDriver.setSessionClosedHandler { [weak self] in self?.handleSessionClosed() }
            do {
                try ptyDriver.startIfNeeded()
                try startControlServer()
                try startStateStreamServer()
                writeRuntimeState(state: .running)
                broadcastCurrentState(reason: TerminalRemoteSessionStateReason.initial)
            } catch {
                terminate()
                throw error
            }
        }

        public func terminate() {
            guard started || vtSession != nil || controlServer != nil || stateStreamServer != nil else { return }
            terminating = true
            let finalPayload = makeStatePayload(reason: TerminalRemoteSessionStateReason.terminated, state: .exited)
            if let finalPayload { try? TerminalSessionPersistence.writeRemoteSessionState(finalPayload, paths: paths) }
            if let finalPayload { stateStreamServer?.broadcast(finalPayload) }
            controlServer?.stop()
            controlServer = nil
            TerminalControlServer.removeSocketFileIfPresent(at: paths.controlSocketPath)
            stateStreamServer?.stop()
            stateStreamServer = nil
            GhosttyRemoteSessionStateStreamServer.removeSocketFileIfPresent(at: paths.subscriptionSocketPath)
            inputOutputResyncTask?.cancel()
            inputOutputResyncTask = nil
            localOwnerCommandInputOutputResyncPending = false
            ptyDriver.setOutputHandler(nil)
            ptyDriver.setSessionClosedHandler(nil)
            ptyDriver.terminate()
            if let vtSession {
                spaces_ghostty_vt_session_free(vtSession)
                self.vtSession = nil
            }
            writeRuntimeState(state: .exited)
            try? TerminalSessionPersistence.detachActiveClients(paths: paths, detachedAt: nowISO8601())
            try? outputHandle?.synchronize()
            try? outputHandle?.close()
            outputHandle = nil
            started = false
            terminating = false
        }

        public func currentRemoteStatePayload(reason: String = TerminalRemoteSessionStateReason.stateChange) -> GhosttyRemoteSessionStatePayload? {
            makeStatePayload(reason: reason, exportMode: .selfContained)
        }

        private func handleSessionClosed() {
            guard !terminating else { return }
            terminate()
            onSessionClosed?(self)
        }

        // MARK: - Exec-in-place handoff

        /// Quiesce this session for the exec-in-place daemon handoff: suppress
        /// broadcasts, stop the per-session resync task, and stop the control +
        /// state-stream servers (removing their socket files exactly as `terminate()`
        /// does) WITHOUT detaching clients, killing the child, or freeing the vt
        /// session. The PTY read loop keeps draining — first into an in-memory buffer,
        /// then straight to `output.log` — so not a byte is lost across the exec.
        /// Returns the handoff record the staged daemon needs to adopt this session, or
        /// nil when there is nothing live to hand off (the child already exited/closed),
        /// in which case the caller terminates the session normally.
        public func quiesceForHandoff() async throws -> DaemonHandoffSessionRecord? {
            handoffTranscriptReplayOffset = nil
            suppressBroadcastsForHandoff = true
            inputOutputResyncTask?.cancel()
            inputOutputResyncTask = nil
            localOwnerCommandInputOutputResyncPending = false

            controlServer?.stop()
            controlServer = nil
            TerminalControlServer.removeSocketFileIfPresent(at: paths.controlSocketPath)
            stateStreamServer?.stop()
            stateStreamServer = nil
            GhosttyRemoteSessionStateStreamServer.removeSocketFileIfPresent(at: paths.subscriptionSocketPath)

            // Nothing live to hand off (child dead/closed): caller terminates normally.
            guard let descriptor = ptyDriver.handoffDescriptorSnapshot() else { return nil }

            // Route further PTY bytes into an in-memory buffer so the read loop never
            // blocks while we drain the main actor and close the durable output handle.
            await ptyDriver.beginHandoffOutputBuffering()

            // The PTY callback registers this second fence before returning and only
            // completes it after its main-actor handleOutput task has appended output.log.
            // The driver's fence above makes the registration set stable; this drain proves
            // every registered persistence task completed without relying on timing.
            await outputDeliveryFence.waitUntilDrained()

            if let outputHandle {
                do {
                    try outputHandle.synchronize()
                    try outputHandle.close()
                    self.outputHandle = nil
                } catch {
                    try? outputHandle.close()
                    self.outputHandle = nil
                    throw error
                }
            }
            handoffTranscriptReplayOffset = try transcriptByteCount()

            // Flush the buffered bytes to output.log and install the direct-to-file writer
            // that keeps appending until execv.
            try ptyDriver.finishHandoffOutputBuffering(appendingTo: paths.outputPath)

            return DaemonHandoffSessionRecord(
                sessionID: launchConfiguration.sessionID, masterFD: descriptor.masterFD, childPID: descriptor.childPID, columns: terminalSize.columns,
                rows: terminalSize.rows, ownerEpoch: ownerEpoch, screenStateRevision: screenStateRevision, appearance: currentAppearance.rawValue)
        }

        /// Holds the PTY sink boundary while the daemon performs its final persistence
        /// validation and `execv`, preventing a direct write from racing after the check.
        public func withValidatedHandoffOutputForExec<T>(_ operation: () throws -> T) throws -> T {
            try ptyDriver.withValidatedHandoffOutputForExec(operation)
        }

        /// Failed-`execv` fallback: `execv` returned, so this same image keeps running and
        /// nothing was freed. Stop the direct-to-file writer, reopen the output handle for
        /// append, restart the per-session servers, and resume broadcasts. This rebinds the
        /// still-live session; it never rebuilds it. This core has no periodic timers to
        /// resume — its resync task is armed on demand — so refreshing runtime state is the
        /// whole catch-up.
        public func resumeInPlaceAfterFailedExec() async {
            ptyDriver.pauseHandoffOutputForFallback()
            if let handoffTranscriptReplayOffset {
                do {
                    _ = try Self.replayOutputLog(at: paths.outputPath, startingAt: handoffTranscriptReplayOffset) { self.writeVTRenderer($0) }
                } catch {
                    FileHandle.standardError.write(Data("spaces: ghostty handoff transcript replay failed: \(error)\n".utf8))
                }
            }
            do {
                try openOutputHandlePreservingTranscript()
            } catch { FileHandle.standardError.write(Data("spaces: ghostty handoff transcript reopen failed: \(error)\n".utf8)) }
            ptyDriver.endHandoffOutputBuffering()
            await outputDeliveryFence.waitUntilDrained()
            self.handoffTranscriptReplayOffset = nil
            suppressBroadcastsForHandoff = false
            do {
                try startControlServer()
                try startStateStreamServer()
            } catch { FileHandle.standardError.write(Data("spaces: ghostty handoff resume-in-place failed: \(error)\n".utf8)) }
            writeRuntimeState(state: .running)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.initial)
        }

        /// Resume side of the exec-in-place handoff, run on a freshly built core in the
        /// staged daemon image for a session that survived the exec. Rebuilds the vt
        /// session at the persisted grid size and replays output.log (via
        /// `recreateVTRenderer`), adopts the inherited PTY, then restarts the servers and
        /// republishes a full frame so reconnecting clients get a self-contained baseline.
        ///
        /// This core's replay is synchronous libghostty-vt (`recreateVTRenderer` writes the
        /// transcript straight into the vt session), unlike the macOS core whose replay
        /// blocks on tick-pumped GhosttyKit IO. So there is no off-main-actor dance: the
        /// replay runs inline. The method stays `async` only for API symmetry with the
        /// macOS core so stage 5's daemon call site compiles unchanged on both platforms.
        public func resumeFromHandoff(_ record: DaemonHandoffSessionRecord) async throws {
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            // Preserve output.log: recreateVTRenderer replays it to rebuild the screen.
            try openOutputHandlePreservingTranscript()

            // Apply the persisted grid and appearance BEFORE building the vt session so the
            // replayed frames wrap at the persisted width and carry the right colors
            // (makeVTSession reads both).
            terminalSize = (columns: record.columns, rows: record.rows)
            if let appearanceRaw = record.appearance, let appearance = ThemeAppearance(rawValue: appearanceRaw) { currentAppearance = appearance }

            started = true
            terminating = false
            suppressBroadcastsForHandoff = false
            installOutputHandler()
            ptyDriver.setSessionClosedHandler { [weak self] in self?.handleSessionClosed() }

            // Rebuild + replay at the persisted grid. recreateVTRenderer writes output.log
            // synchronously into a replacement VT session, then swaps it in and arms the
            // full-frame flag.
            try recreateVTRenderer(columns: record.columns, rows: record.rows)

            // Adopt the inherited PTY only AFTER replay so no live byte races ahead of the
            // replayed transcript. The read loop starts here.
            ptyDriver.adopt(masterFD: record.masterFD, childPID: record.childPID)

            ownerEpoch = record.ownerEpoch
            // Advance past the recorded revision and force the first broadcast to a full
            // render update so reconnecting clients rebuild from a self-contained baseline.
            screenStateRevision = record.screenStateRevision &+ 1
            renderUpdateBaseline = nil
            forceNextBroadcastFullRenderUpdate = true

            try startControlServer()
            try startStateStreamServer()
            writeRuntimeState(state: .running)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.initial)
        }

        var debugOwnerEpoch: UInt64 { ownerEpoch }
        var isStarted: Bool { started }

        private func installOutputHandler() {
            let outputDeliveryFence = outputDeliveryFence
            ptyDriver.setOutputHandler { [weak self, outputDeliveryFence] data in
                outputDeliveryFence.beginDelivery()
                Task { @MainActor [weak self, outputDeliveryFence] in
                    defer { outputDeliveryFence.finishDelivery() }
                    self?.handleOutput(data)
                }
            }
        }

        private func handleOutput(_ data: Data) {
            guard started, !data.isEmpty else { return }
            logMobileTakeoverPerformance(
                name: "terminal_output_observed", count: data.count,
                attributes: ["output_bytes": String(data.count), "output_byte_count_before": String(outputByteCount)])
            _ = appendTranscript(data)
            writeVTRenderer(data)
            writeRuntimeState(state: .running)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.output)
            scheduleInputOutputResyncIfNeeded()
        }

        @discardableResult private func appendTranscript(_ data: Data) -> Bool {
            guard let outputHandle else { return false }
            do {
                try outputHandle.write(contentsOf: data)
                outputByteCount += data.count
                return true
            } catch { return false }
        }

        private func ensureOutputHandle() throws {
            _ = FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
            outputByteCount = Int(try handle.seekToEnd())
            outputHandle = handle
        }

        /// Opens the durable output handle for append WITHOUT truncating any existing
        /// transcript, for the handoff resume paths. `resumeFromHandoff` replays output.log
        /// (via `recreateVTRenderer`) to rebuild the screen and `resumeInPlaceAfterFailedExec`
        /// continues the same transcript, so both must keep the existing bytes — unlike
        /// `ensureOutputHandle`, whose `createFile(contents: nil)` recreates (and thus
        /// empties) the log for a fresh start. Creating the file only when absent leaves any
        /// existing history in place; `seekToEnd` positions the handle to append and
        /// re-derive the byte count.
        private func openOutputHandlePreservingTranscript() throws {
            guard outputHandle == nil else { return }
            if !FileManager.default.fileExists(atPath: paths.outputPath) {
                _ = FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
            outputByteCount = Int(try handle.seekToEnd())
            outputHandle = handle
        }

        private func transcriptByteCount() throws -> UInt64 {
            guard FileManager.default.fileExists(atPath: paths.outputPath) else { return 0 }
            let attributes = try FileManager.default.attributesOfItem(atPath: paths.outputPath)
            guard let size = attributes[.size] as? NSNumber else { throw POSIXError(.EIO) }
            return size.uint64Value
        }

        private func startControlServer() throws {
            let server = TerminalControlServer(socketPath: paths.controlSocketPath, queue: controlQueue) { [weak self] request in
                Self.runOnMainActorSynchronously {
                    guard let self else {
                        return TerminalControlResponse(ok: false, message: "Terminal session is shutting down.", errorCode: .shuttingDown)
                    }
                    return self.handleControlRequest(request)
                }
            }
            try server.start()
            controlServer = server
        }

        private func startStateStreamServer() throws {
            let server = GhosttyRemoteSessionStateStreamServer(
                socketPath: paths.subscriptionSocketPath, queue: stateStreamQueue,
                initialStateProvider: { [weak self] in
                    Self.runOnMainActorSynchronously {
                        self?.makeStatePayload(
                            reason: TerminalRemoteSessionStateReason.initial, exportMode: .selfContained, markNextBroadcastFull: false)
                    }
                })
            try server.start()
            stateStreamServer = server
        }

        public func handleControlRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            let response: TerminalControlResponse
            switch request.command {
            case "attach": response = attach(request)
            case "detach": response = detach(request)
            case "heartbeat": response = heartbeat(request)
            case "takeover": response = takeover(request)
            case "send": response = send(request)
            case "key": response = key(request)
            case "clearScreen": response = clearScreen(request)
            case "resize": response = resize(request)
            case "scroll": response = scroll(request)
            case "setAppearance": response = setAppearance(request)
            default: response = TerminalControlResponse(ok: false, message: "Unsupported terminal command '\(request.command)'.")
            }
            logMobileTakeoverPerformance(
                name: "terminal_control_host_handle", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                attributes: [
                    "action": request.command, "ok": response.ok ? "1" : "0", "client_id": request.clientID ?? "nil",
                    "owner_epoch": request.ownerEpoch.map(String.init) ?? "nil",
                ])
            return response
        }

        private func attach(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard let client = request.client else {
                return TerminalControlResponse(ok: false, message: "Missing client payload.", errorCode: .invalidArgument)
            }
            let mode = request.attachmentMode ?? .viewer
            do {
                // Adopt the attaching client's light/dark appearance before broadcasting, so the
                // state the client receives on attach already carries the matching theme variant.
                if let appearance = request.appearance { applyThemeAppearance(appearance) }
                let previousOwner = activeOwnerClientID()
                try TerminalSessionPersistence.attachClient(
                    sessionID: launchConfiguration.sessionID, client: client, mode: mode, paths: paths, attachedAt: nowISO8601())
                if mode == .owner, previousOwner != client.id { advanceOwnerEpoch() }
                writeRuntimeState(state: .running)
                broadcastCurrentState(reason: TerminalRemoteSessionStateReason.attachmentState)
                return TerminalControlResponse(ok: true, message: "Attached \(mode.rawValue) client.")
            } catch { return TerminalControlResponse(ok: false, message: String(describing: error)) }
        }

        private func detach(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard let clientID = request.clientID else {
                return TerminalControlResponse(ok: false, message: "Missing client ID.", errorCode: .invalidArgument)
            }
            do {
                let detachedOwner = activeOwnerClientID() == clientID
                try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: nowISO8601())
                if detachedOwner { advanceOwnerEpoch() }
                writeRuntimeState(state: .running)
                broadcastCurrentState(reason: TerminalRemoteSessionStateReason.attachmentState)
                return TerminalControlResponse(ok: true, message: "Detached terminal client.")
            } catch { return TerminalControlResponse(ok: false, message: String(describing: error)) }
        }

        private func heartbeat(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard let clientID = request.clientID else {
                return TerminalControlResponse(ok: false, message: "Missing client ID.", errorCode: .invalidArgument)
            }
            do {
                try TerminalSessionPersistence.touchClient(id: clientID, paths: paths, touchedAt: nowISO8601())
                return TerminalControlResponse(ok: true, message: "Refreshed terminal client lease.")
            } catch { return TerminalControlResponse(ok: false, message: String(describing: error)) }
        }

        private func takeover(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard let clientID = request.clientID else {
                return TerminalControlResponse(ok: false, message: "Missing client ID.", errorCode: .invalidArgument)
            }
            do {
                try? TerminalSessionPersistence.touchClient(id: clientID, paths: paths, touchedAt: nowISO8601())
                let previousOwner = activeOwnerClientID()
                try TerminalSessionPersistence.transferOwnership(
                    sessionID: launchConfiguration.sessionID, newOwnerClientID: clientID, paths: paths, transferredAt: nowISO8601())
                if previousOwner != clientID { advanceOwnerEpoch() }
                writeRuntimeState(state: .running)
                broadcastCurrentState(reason: TerminalRemoteSessionStateReason.attachmentState)
                return TerminalControlResponse(ok: true, message: "Transferred terminal ownership.")
            } catch { return TerminalControlResponse(ok: false, message: String(describing: error)) }
        }

        private func send(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else {
                return TerminalControlResponse(ok: false, message: "Only the active owner can send input.", errorCode: .ownershipRejected)
            }
            if request.asPaste {
                guard var text = request.text, request.bytes == nil else {
                    return TerminalControlResponse(ok: false, message: "Paste input requires text payload.", errorCode: .invalidArgument)
                }
                if request.appendNewline { text.append("\n") }
                guard let payload = encodePastePayload(text) else {
                    return TerminalControlResponse(ok: false, message: "Unable to encode paste input.", errorCode: .internalError)
                }
                markLocalOwnerCommandInputOutputResyncPending()
                ptyDriver.sendRawBytes(payload)
                return TerminalControlResponse(ok: true, message: "Sent input.")
            }
            guard var payload = request.inputPayload else {
                return TerminalControlResponse(ok: false, message: "Missing input payload.", errorCode: .invalidArgument)
            }
            if request.appendNewline { payload.append(0x0A) }
            markLocalOwnerCommandInputOutputResyncPending()
            ptyDriver.sendRawBytes(payload)
            return TerminalControlResponse(ok: true, message: "Sent input.")
        }

        private func encodePastePayload(_ text: String) -> Data? {
            guard let vtSession else { return nil }
            let data = Data(text.utf8)
            var encodedPointer: UnsafeMutablePointer<CChar>?
            var encodedLength: size_t = 0
            let encoded = data.withUnsafeBytes { rawBuffer -> Bool in
                if data.isEmpty { return spaces_ghostty_vt_session_encode_paste(vtSession, nil, 0, &encodedPointer, &encodedLength) }
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return false }
                return spaces_ghostty_vt_session_encode_paste(vtSession, baseAddress, data.count, &encodedPointer, &encodedLength)
            }
            guard encoded else { return nil }
            defer { if let encodedPointer { spaces_ghostty_vt_free_buffer(encodedPointer) } }
            guard let encodedPointer, encodedLength > 0 else { return Data() }
            return Data(bytes: encodedPointer, count: encodedLength)
        }

        private func key(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else {
                return TerminalControlResponse(ok: false, message: "Only the active owner can send input.", errorCode: .ownershipRejected)
            }
            guard let key = request.key, let bytes = TerminalKeyInput.bytes(for: key) else {
                return TerminalControlResponse(ok: false, message: "Unsupported terminal key.", errorCode: .invalidArgument)
            }
            if bytes.contains(0x0D) { markLocalOwnerCommandInputOutputResyncPending() }
            ptyDriver.sendRawBytes(Data(bytes))
            return TerminalControlResponse(ok: true, message: "Sent key.")
        }

        private func clearScreen(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else {
                return TerminalControlResponse(ok: false, message: "Only the active owner can clear the terminal.", errorCode: .ownershipRejected)
            }
            let mutation = GhosttyTerminalTranscriptMutation.clearScreenAndScrollback
            guard appendTranscript(mutation) else {
                return TerminalControlResponse(ok: false, message: "Unable to persist the terminal clear operation.")
            }
            writeVTRenderer(mutation)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.clearScreen)
            return TerminalControlResponse(ok: true, message: "Cleared terminal screen and scrollback.")
        }

        private func resize(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else {
                return TerminalControlResponse(ok: false, message: "Only the active owner can resize the terminal.", errorCode: .ownershipRejected)
            }
            guard let columns = request.columns, let rows = request.rows, columns > 0, rows > 0 else {
                return TerminalControlResponse(ok: false, message: "Missing terminal size.", errorCode: .invalidArgument)
            }
            do { try recreateVTRenderer(columns: columns, rows: rows) } catch {
                return TerminalControlResponse(ok: false, message: "Unable to resize the terminal renderer: \(error)")
            }
            terminalSize = (columns, rows)
            _ = ptyDriver.resizeCellGrid(columns: columns, rows: rows)
            writeRuntimeState(state: .running)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.resize)
            return TerminalControlResponse(ok: true, message: "Resized terminal.")
        }

        private func scroll(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else {
                return TerminalControlResponse(ok: false, message: "Only the active owner can scroll the terminal.", errorCode: .ownershipRejected)
            }
            guard let vtSession else { return TerminalControlResponse(ok: false, message: "Terminal renderer is unavailable.") }
            let vertical = request.scrollVertical ?? 0
            let scrollMods = request.scrollMods ?? 0
            let deltaRows = scrollDeltaNormalizer.terminalViewportDeltaRows(vertical: vertical, scrollMods: scrollMods)
            guard deltaRows != 0 else { return TerminalControlResponse(ok: true, message: "Ignored zero scroll delta.") }
            var attributes = [
                "action": request.command, "client_id": request.clientID ?? "nil", "delta_rows": String(deltaRows),
                "owner_epoch": request.ownerEpoch.map(String.init) ?? "nil", "scroll_mods": String(scrollMods), "scroll_vertical": String(vertical),
            ]
            let nativeStartedAt = Date()
            var beforeScrollbar = SpacesGhosttyVtScrollbar()
            var afterScrollbar = SpacesGhosttyVtScrollbar()
            guard spaces_ghostty_vt_session_scroll_viewport_with_info(vtSession, deltaRows, &beforeScrollbar, &afterScrollbar) else {
                return TerminalControlResponse(ok: false, message: "Unable to scroll terminal.")
            }
            attributes["scrollbar_before"] = "\(beforeScrollbar.offset)/\(beforeScrollbar.total)"
            attributes["scrollbar_after"] = "\(afterScrollbar.offset)/\(afterScrollbar.total)"
            guard beforeScrollbar.offset != afterScrollbar.offset else {
                logMobileTakeoverPerformance(
                    name: "scroll_native_end", elapsedMS: TerminalPerformance.elapsedMS(since: nativeStartedAt), attributes: attributes)
                return TerminalControlResponse(ok: true, message: "Already at scroll boundary.")
            }
            logMobileTakeoverPerformance(
                name: "scroll_native_end", elapsedMS: TerminalPerformance.elapsedMS(since: nativeStartedAt), attributes: attributes)
            screenStateRevision &+= 1
            let broadcastStartedAt = Date()
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.scroll)
            logMobileTakeoverPerformance(
                name: "scroll_broadcast_end", elapsedMS: TerminalPerformance.elapsedMS(since: broadcastStartedAt), attributes: attributes)
            return TerminalControlResponse(ok: true, message: "Scrolled terminal.")
        }

        private func setAppearance(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard let appearance = request.appearance else {
                return TerminalControlResponse(ok: false, message: "Missing appearance.", errorCode: .invalidArgument)
            }
            // Don't re-theme an exited session (parity with the macOS host's isRuntimeInteractiveForControl
            // guard). The renderer is freed on exit, and the control socket is torn down with it, so this
            // is the same not-running check the scroll handler makes before touching the vt session.
            guard started, vtSession != nil else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            // Appearance is a per-client view preference on a shared session with last-writer-wins
            // semantics, so it is deliberately NOT owner-gated: any attached client may re-theme the
            // terminal it is watching.
            guard appearance != currentAppearance else {
                return TerminalControlResponse(ok: true, message: "Terminal already matches the requested appearance.")
            }
            // The vt re-theme is synchronous (unlike the macOS io thread), and applyThemeAppearance
            // arms the full-frame flag and bumps the screen revision, so broadcast right after to push
            // the recolored full frame to subscribers promptly.
            applyThemeAppearance(appearance)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.stateChange)
            return TerminalControlResponse(ok: true, message: "Applied \(appearance.rawValue) appearance.")
        }

        private func ownerRequestIsCurrent(_ request: TerminalControlRequest) -> Bool {
            // Requests without a client ID are daemon-local trusted callers — the profile terminal
            // commands and the agent-facing Device API send path — which are deliberately not
            // attachment-gated. This matches the macOS host's ownerRequestRejection semantics; the
            // owner gate exists to arbitrate between attached rendering clients, not to block agents.
            guard let clientID = request.clientID else { return true }
            guard activeOwnerClientID() == clientID else { return false }
            guard let requestedOwnerEpoch = request.ownerEpoch else { return true }
            return requestedOwnerEpoch == ownerEpoch
        }

        private func activeOwnerClientID() -> String? {
            ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).first { $0.mode == .owner }?.clientID
        }

        private func activeOwnerClient() -> TerminalClient? {
            guard let snapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths),
                let ownerID = TerminalRemoteSessionStatePolicy.activeOwnerClientID(in: snapshot)
            else { return nil }
            return snapshot.clients.first { $0.id == ownerID }
        }

        private func advanceOwnerEpoch() { ownerEpoch &+= 1 }

        private func markLocalOwnerCommandInputOutputResyncPending() {
            guard activeOwnerClient()?.kind == .localWindow else { return }
            localOwnerCommandInputOutputResyncPending = true
        }

        private func scheduleInputOutputResyncIfNeeded() {
            guard localOwnerCommandInputOutputResyncPending else { return }
            localOwnerCommandInputOutputResyncPending = false
            inputOutputResyncTask?.cancel()
            inputOutputResyncTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self else { return }
                self.inputOutputResyncTask = nil
                self.broadcastCurrentState(reason: TerminalRemoteSessionStateReason.inputOutput)
            }
        }

        private func writeVTRenderer(_ data: Data) {
            guard let vtSession, !data.isEmpty else { return }
            data.withUnsafeBytes { rawBuffer in
                _ = spaces_ghostty_vt_session_write(vtSession, rawBuffer.bindMemory(to: UInt8.self).baseAddress, rawBuffer.count)
            }
            screenStateRevision &+= 1
        }

        /// Rebuilds the VT renderer from the append-only transcript without ever
        /// materializing the whole file in memory. Replay happens into a replacement
        /// session first, so a read or VT-write failure leaves the current renderer
        /// intact and handoff resume can fail before adopting the inherited PTY.
        private func recreateVTRenderer(columns: Int, rows: Int) throws {
            guard let replacementSession = makeVTSession(columns: columns, rows: rows) else {
                throw GhosttyLinuxHeadlessSessionError.vtSessionUnavailable
            }
            do {
                let replayedOutput = try Self.replayOutputLog(at: paths.outputPath) { chunk in
                    let succeeded = chunk.withUnsafeBytes { rawBuffer in
                        spaces_ghostty_vt_session_write(replacementSession, rawBuffer.bindMemory(to: UInt8.self).baseAddress, rawBuffer.count)
                    }
                    guard succeeded else { throw GhosttyLinuxHeadlessSessionError.vtReplayFailed }
                }
                if let vtSession { spaces_ghostty_vt_session_free(vtSession) }
                vtSession = replacementSession
                renderUpdateBaseline = nil
                forceNextBroadcastFullRenderUpdate = true
                if replayedOutput { screenStateRevision &+= 1 }
            } catch {
                spaces_ghostty_vt_session_free(replacementSession)
                throw error
            }
        }

        /// Streams a transcript through `consume` in fixed-size chunks. Internal so
        /// tests can enforce the memory-bound contract independently of file size.
        @discardableResult nonisolated static func replayOutputLog(
            at path: String, startingAt offset: UInt64 = 0, consume: (Data) throws -> Void
        ) throws -> Bool {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            var replayedOutput = false
            while let chunk = try handle.read(upToCount: outputReplayChunkByteCount), !chunk.isEmpty {
                try consume(chunk)
                replayedOutput = true
            }
            return replayedOutput
        }

        /// Creates a headless vt session themed with the Spaces terminal colors, so the render
        /// frames this daemon streams to the client match the app instead of libghostty-vt's default
        /// palette. The daemon resolves the palette itself from the shared theme registry (it links
        /// `spacesterminalcore`); the attaching client conveys only its light/dark appearance
        /// (`applyThemeAppearance(_:)`), since the headless daemon cannot read the client's OS
        /// appearance. Until a client attaches, the session uses the default (dark) appearance.
        private func makeVTSession(columns: Int, rows: Int) -> OpaquePointer? {
            var theme = Self.vtTheme(export: ActiveTheme.descriptor.terminal(for: currentAppearance))
            return withUnsafePointer(to: &theme) { themePointer in
                spaces_ghostty_vt_session_new(UInt16(clamping: columns), UInt16(clamping: rows), Self.maxScrollbackBytes, themePointer)
            }
        }

        /// Re-themes the live session to the attaching client's appearance and forces the next
        /// broadcast to send a full frame so the recolored screen reaches the client immediately.
        /// A no-op when the appearance is unchanged, so repeated attaches do not churn full frames.
        private func applyThemeAppearance(_ appearance: ThemeAppearance) {
            guard appearance != currentAppearance else { return }
            currentAppearance = appearance
            guard let vtSession else { return }
            var theme = Self.vtTheme(export: ActiveTheme.descriptor.terminal(for: appearance))
            let applied = withUnsafePointer(to: &theme) { spaces_ghostty_vt_session_set_theme(vtSession, $0) }
            guard applied else { return }
            screenStateRevision &+= 1
            forceNextBroadcastFullRenderUpdate = true
        }

        /// Packs a theme's terminal export into the C shim's theme struct (default fg/bg/cursor plus
        /// the 16 ANSI palette entries; the shim fills 16-255 with the standard xterm ramp).
        private static func vtTheme(export: GhosttyThemeExport) -> SpacesGhosttyVtTheme {
            var theme = SpacesGhosttyVtTheme()
            theme.foreground_rgb = export.foreground.packedRGB
            theme.background_rgb = export.background.packedRGB
            theme.cursor_rgb = export.cursorColor.packedRGB
            withUnsafeMutablePointer(to: &theme.palette_rgb) { tuplePointer in
                tuplePointer.withMemoryRebound(to: UInt32.self, capacity: 16) { buffer in
                    for index in 0..<16 { buffer[index] = index < export.palette.count ? export.palette[index].packedRGB : 0 }
                }
            }
            return theme
        }

        private func writeRuntimeState(state: TerminalSessionState) {
            let liveChildPID = ptyDriver.childPID()
            if let liveChildPID { lastKnownChildPID = liveChildPID }
            let foregroundPID = ptyDriver.foregroundPID()
            let foregroundProcess = foregroundPID.flatMap { TerminalForegroundProcessInspector.inspect(pid: $0) }
            let foregroundAgent = foregroundProcess.flatMap { TerminalForegroundProcessInspector.classify($0) }
            let runtimeState = TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(),
                childPID: liveChildPID ?? lastKnownChildPID, state: state, updatedAt: nowISO8601(),
                exitedAt: state.isInteractive ? nil : nowISO8601(), title: launchConfiguration.title,
                workingDirectory: launchConfiguration.workingDirectory, columns: terminalSize.columns, rows: terminalSize.rows,
                foregroundPID: foregroundPID, foregroundExecutablePath: foregroundProcess?.executablePath,
                foregroundExecutableName: foregroundProcess?.executableName, foregroundArgv: foregroundProcess?.argv,
                foregroundDetectedAgentKind: foregroundAgent?.detectedAgentKind, foregroundDisplayLabel: foregroundAgent?.displayLabel,
                foregroundDisplayCommand: foregroundAgent?.displayCommand)
            let previousSignature = lastRuntimeState.map(runtimeStateSignature(for:))
            let nextSignature = runtimeStateSignature(for: runtimeState)
            try? TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
            lastRuntimeState = runtimeState
            if previousSignature != nextSignature { postRuntimeStateDidChange() }
        }

        private func postRuntimeStateDidChange() {
            TerminalSessionNotification.post(.spacesTerminalRuntimeStateDidChange, sessionID: launchConfiguration.sessionID)
            TerminalOverviewSignal.post()
        }

        private func broadcastCurrentState(reason: String) {
            guard !suppressBroadcastsForHandoff else { return }
            let performanceLoggingEnabled = SpacesDeviceTerminalPerformanceLogger.isEnabled()
            let startedAt = performanceLoggingEnabled ? Date() : nil
            guard let payload = makeStatePayload(reason: reason, exportMode: .streamDeltaAllowed) else { return }
            stateStreamServer?.broadcast(payload)
            guard performanceLoggingEnabled, let startedAt else { return }
            let payloadEncodeStartedAt = Date()
            let encodedPayload = try? GhosttyRemoteSessionStateCodec.encodeLine(payload)
            let payloadEncodeMS = TerminalPerformance.elapsedMS(since: payloadEncodeStartedAt)
            let payloadBytes = encodedPayload?.count ?? 0
            let decodedUpdate = payload.decodedRenderUpdate
            let attributes = GhosttyRenderFrameMetrics.attributes(
                reason: payload.reason, frame: decodedUpdate?.fullFrame, payloadByteCount: payloadBytes, payloadEncodeMS: payloadEncodeMS,
                outputByteCount: outputByteCount, screenStateRevision: payload.screenStateRevision, frameKind: decodedUpdate?.frameKindMetricValue,
                baseRevision: decodedUpdate?.baseRevision, targetRevision: decodedUpdate?.targetRevision ?? payload.screenStateRevision,
                operationCount: decodedUpdate?.operationCount, changedCellCount: decodedUpdate?.changedCellCount,
                scrollOperationCount: decodedUpdate?.scrollOperationCount, fullFrameFallbackReason: decodedUpdate?.fallbackReason)
            logMobileTakeoverPerformance(
                name: "remote_state_publish", count: payloadBytes,
                attributes: [
                    "reason": payload.reason, "owner_kind": activeOwnerClient()?.kind.rawValue ?? "nil", "payload_bytes": String(payloadBytes),
                    "render_update": payload.renderUpdate == nil ? "0" : "1", "render_update_bytes": String(payload.renderUpdate?.count ?? 0),
                ])
            logMobileTakeoverPerformance(
                name: "render_frame_payload_publish", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), count: payloadBytes,
                attributes: attributes)
        }

        private func makeStatePayload(
            reason: String, state: TerminalSessionState? = nil, exportMode: RenderStateExportMode = .selfContained,
            markNextBroadcastFull: Bool = false
        ) -> GhosttyRemoteSessionStatePayload? {
            let attachmentSnapshot = (try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? TerminalSessionAttachmentSnapshot()
            let ownerKind = TerminalRemoteSessionStatePolicy.activeOwnerClientKind(in: attachmentSnapshot)
            let includeScreenState = TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: reason, ownerKind: ownerKind)
            let runtimeState: TerminalSessionRuntimeState
            if let state {
                writeRuntimeState(state: state)
                runtimeState = lastRuntimeState ?? fallbackRuntimeState(state: state)
            } else {
                runtimeState = lastRuntimeState ?? fallbackRuntimeState(state: started ? .running : .exited)
            }
            let frame: GhosttyRenderFrame?
            let renderUpdateValue: GhosttyRenderUpdate?
            let renderUpdate: Data?
            if includeScreenState {
                let performanceLoggingEnabled = SpacesDeviceTerminalPerformanceLogger.isEnabled()
                let snapshotExportStartedAt = performanceLoggingEnabled ? Date() : nil
                frame = try? renderFrame()
                let renderUpdateEncodeStartedAt = performanceLoggingEnabled ? Date() : nil
                renderUpdateValue = frame.map { makeRenderUpdate(for: $0, reason: reason, exportMode: exportMode) }
                renderUpdate = renderUpdateValue.flatMap { try? GhosttyRenderUpdateBinaryCodec.encode($0) }
                if performanceLoggingEnabled, let snapshotExportStartedAt, let renderUpdateEncodeStartedAt {
                    let renderUpdateEncodeMS = TerminalPerformance.elapsedMS(since: renderUpdateEncodeStartedAt)
                    var attributes = GhosttyRenderFrameMetrics.attributes(
                        reason: reason, frame: frame, outputByteCount: outputByteCount, screenStateRevision: screenStateRevision,
                        frameKind: renderUpdateValue?.frameKindMetricValue, baseRevision: renderUpdateValue?.baseRevision,
                        targetRevision: renderUpdateValue?.targetRevision ?? screenStateRevision, operationCount: renderUpdateValue?.operationCount,
                        changedCellCount: renderUpdateValue?.changedCellCount, scrollOperationCount: renderUpdateValue?.scrollOperationCount,
                        fullFrameFallbackReason: renderUpdateValue?.fallbackReason)
                    attributes["owner_kind"] = ownerKind?.rawValue ?? "nil"
                    attributes["render_update_bytes"] = String(renderUpdate?.count ?? 0)
                    attributes["render_update_encode_ms"] = String(renderUpdateEncodeMS)
                    logMobileTakeoverPerformance(
                        name: "render_frame_export_end", elapsedMS: TerminalPerformance.elapsedMS(since: snapshotExportStartedAt),
                        count: renderUpdate?.count, attributes: attributes)
                }
            } else {
                frame = nil
                renderUpdateValue = nil
                renderUpdate = nil
            }
            if renderUpdate != nil, markNextBroadcastFull { forceNextBroadcastFullRenderUpdate = true }
            return GhosttyRemoteSessionStatePayload(
                sessionID: launchConfiguration.sessionID, reason: reason, emittedAt: nowISO8601(), sessionStateRevision: nil, sessionStateFlags: nil,
                screenStateRevision: screenStateRevision, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
                title: launchConfiguration.title, workingDirectory: launchConfiguration.workingDirectory, outputByteCount: outputByteCount,
                outputEndByteOffset: outputByteCount, renderUpdate: renderUpdate)
        }

        private func makeRenderUpdate(for frame: GhosttyRenderFrame, reason: String, exportMode: RenderStateExportMode) -> GhosttyRenderUpdate {
            let forceFullForSelfContainedExport = exportMode == .selfContained
            let hasPendingSubscriberBaselineReset = exportMode == .streamDeltaAllowed && forceNextBroadcastFullRenderUpdate
            let forceFullForSubscriberBaseline = hasPendingSubscriberBaselineReset && reason != TerminalRemoteSessionStateReason.scroll
            let forceFullForExplicitResync =
                reason == TerminalRemoteSessionStateReason.initial || reason == TerminalRemoteSessionStateReason.resize
                || reason == TerminalRemoteSessionStateReason.terminated
            let forceFull =
                forceFullForSelfContainedExport || forceFullForSubscriberBaseline || forceFullForExplicitResync
                || renderUpdateBaseline?.sessionRevision == frame.sessionRevision
            let forceFullReason =
                if reason == TerminalRemoteSessionStateReason.initial { "initial_baseline" } else if reason == TerminalRemoteSessionStateReason.resize
                { "resize_self_contained" } else if reason == TerminalRemoteSessionStateReason.terminated {
                    "explicit_resync"
                } else if forceFullForSubscriberBaseline { "subscriber_baseline_reset" } else if forceFullForSelfContainedExport {
                    "self_contained_state_export"
                } else { "baseline_already_current" }
            let update = GhosttyRenderUpdateFactory.makeUpdate(
                target: frame, baseline: renderUpdateBaseline, forceFull: forceFull, forceFullReason: forceFullReason)
            let shouldUpdateStreamBaseline = exportMode == .streamDeltaAllowed
            switch update.kind {
            case .full: if shouldUpdateStreamBaseline { renderUpdateBaseline = GhosttyRenderUpdateBaseline(frame: frame) }
            case .delta:
                if let baseline = try? GhosttyRenderUpdateApplier.apply(update, to: renderUpdateBaseline) {
                    renderUpdateBaseline = baseline
                } else {
                    if shouldUpdateStreamBaseline { renderUpdateBaseline = GhosttyRenderUpdateBaseline(frame: frame) }
                    return GhosttyRenderUpdate.full(frame, fallbackReason: "linux_delta_apply_failed")
                }
            case .resyncRequired: if shouldUpdateStreamBaseline { renderUpdateBaseline = nil }
            }
            if hasPendingSubscriberBaselineReset { forceNextBroadcastFullRenderUpdate = false }
            return update
        }

        private func renderFrame() throws -> GhosttyRenderFrame {
            guard let vtSession else { throw GhosttyLinuxHeadlessSessionError.vtSessionUnavailable }
            var rawSnapshot = SpacesGhosttyVtSnapshot()
            guard spaces_ghostty_vt_session_copy_snapshot(vtSession, &rawSnapshot) else { throw GhosttyLinuxHeadlessSessionError.snapshotUnavailable }
            defer { spaces_ghostty_vt_snapshot_free(&rawSnapshot) }
            let cells: [GhosttyTerminalSnapshot.Cell]
            if let rawCells = rawSnapshot.cells, rawSnapshot.cell_count > 0 {
                cells = UnsafeBufferPointer(start: rawCells, count: rawSnapshot.cell_count).map {
                    GhosttyTerminalSnapshot.Cell(
                        codepoint: $0.codepoint, foregroundRGB: $0.foreground_rgb, backgroundRGB: $0.background_rgb, flags: $0.flags)
                }
            } else {
                cells = []
            }
            let snapshot = GhosttyTerminalSnapshot(
                columns: Int(rawSnapshot.columns), rows: Int(rawSnapshot.rows), cursorColumn: Int(rawSnapshot.cursor_column),
                cursorRow: Int(rawSnapshot.cursor_row), cursorVisible: rawSnapshot.cursor_visible,
                defaultForegroundRGB: rawSnapshot.default_foreground_rgb, defaultBackgroundRGB: rawSnapshot.default_background_rgb, cells: cells)
            return GhosttyRenderFrame(sessionRevision: screenStateRevision, ownerEpoch: ownerEpoch, snapshot: snapshot)
        }

        private func fallbackRuntimeState(state: TerminalSessionState) -> TerminalSessionRuntimeState {
            TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: lastKnownChildPID,
                state: state, updatedAt: nowISO8601(), exitedAt: state.isInteractive ? nil : nowISO8601(), title: launchConfiguration.title,
                workingDirectory: launchConfiguration.workingDirectory, columns: terminalSize.columns, rows: terminalSize.rows)
        }

        private func runtimeStateSignature(for state: TerminalSessionRuntimeState) -> String {
            "\(state.sessionID)|\(state.backend.rawValue)|\(state.servicePID)|\(state.childPID.map(String.init) ?? "nil")|\(state.foregroundPID.map(String.init) ?? "nil")|\(state.foregroundExecutablePath ?? "nil")|\(state.foregroundExecutableName ?? "nil")|\(state.foregroundArgv?.joined(separator: "\u{1F}") ?? "nil")|\(state.foregroundDetectedAgentKind?.rawValue ?? "nil")|\(state.foregroundDisplayLabel ?? "nil")|\(state.foregroundDisplayCommand ?? "nil")|\(state.title ?? "nil")|\(state.workingDirectory ?? "nil")|\(state.columns.map(String.init) ?? "nil")|\(state.rows.map(String.init) ?? "nil")|\(state.state.rawValue)|\(state.exitedAt ?? "nil")"
        }

        private func nowISO8601() -> String { GhosttyRemoteSessionStateTimestamp.string(from: Date()) }

        private func logMobileTakeoverPerformance(name: String, elapsedMS: Int? = nil, count: Int? = nil, attributes: [String: String] = [:]) {
            SpacesDeviceTerminalPerformanceLogger.emit(
                .init(
                    sessionID: launchConfiguration.sessionID, source: "linux-host", name: name, elapsedMS: elapsedMS, count: count,
                    attributes: attributes))
        }

        nonisolated private static func runOnMainActorSynchronously<T: Sendable>(_ work: @MainActor @Sendable @escaping () -> T) -> T {
            if Thread.isMainThread { return MainActor.assumeIsolated(work) }
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: T?
            Task { @MainActor in
                result = work()
                semaphore.signal()
            }
            semaphore.wait()
            guard let result else { fatalError("MainActor synchronous task completed without a result.") }
            return result
        }
    }
#endif
