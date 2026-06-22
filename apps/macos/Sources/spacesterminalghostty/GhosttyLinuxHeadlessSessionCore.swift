#if os(Linux)
    import Dispatch
    import Foundation
    import Glibc
    import ghosttyvtshim
    import spacesterminalcore

    enum GhosttyLinuxHeadlessSessionError: LocalizedError {
        case vtSessionUnavailable
        case snapshotUnavailable

        var errorDescription: String? {
            switch self {
            case .vtSessionUnavailable: "libghostty-vt is not available for the headless terminal session."
            case .snapshotUnavailable: "Unable to export a headless terminal render frame."
            }
        }
    }

    @MainActor public final class GhosttyEmbeddedSessionCore {
        private static let maxScrollbackBytes = TerminalScrollbackBudget.defaultMaxBytes

        private enum RenderStateExportMode {
            case selfContained
            case streamDeltaAllowed
        }

        public let launchConfiguration: TerminalSessionLaunchConfiguration
        public let paths: TerminalSessionPaths

        private let controlQueue: DispatchQueue
        private let stateStreamQueue: DispatchQueue
        private let ptyDriver: HostManagedPTYTerminalSessionDriver
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
        private var ownerEpoch: UInt64 = 0
        private var screenStateRevision: UInt64 = 0
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
            guard
                let vtSession = spaces_ghostty_vt_session_new(
                    UInt16(clamping: terminalSize.columns), UInt16(clamping: terminalSize.rows), Self.maxScrollbackBytes)
            else { throw GhosttyLinuxHeadlessSessionError.vtSessionUnavailable }
            self.vtSession = vtSession
            started = true
            terminating = false
            writeRuntimeState(state: .starting)
            ptyDriver.setOutputHandler { [weak self] data in Task { @MainActor [weak self] in self?.handleOutput(data) } }
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

        private func handleOutput(_ data: Data) {
            guard started, !data.isEmpty else { return }
            logMobileTakeoverPerformance(
                name: "terminal_output_observed", count: data.count,
                attributes: ["output_bytes": String(data.count), "output_byte_count_before": String(outputByteCount)])
            do {
                try outputHandle?.write(contentsOf: data)
                outputByteCount += data.count
            } catch {}
            writeVTRenderer(data)
            writeRuntimeState(state: .running)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.output)
            scheduleInputOutputResyncIfNeeded()
        }

        private func ensureOutputHandle() throws {
            _ = FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
            outputByteCount = Int(try handle.seekToEnd())
            outputHandle = handle
        }

        private func startControlServer() throws {
            let server = TerminalControlServer(socketPath: paths.controlSocketPath, queue: controlQueue) { [weak self] request in
                Self.runOnMainActorSynchronously {
                    guard let self else { return TerminalControlResponse(ok: false, message: "Terminal session is shutting down.") }
                    return self.handleControlRequest(request)
                }
            }
            try server.start()
            controlServer = server
        }

        private func startStateStreamServer() throws {
            let server = GhosttyRemoteSessionStateStreamServer(
                socketPath: paths.subscriptionSocketPath, queue: stateStreamQueue,
                initialStateProviderWithConnectionState: { [weak self] hasExistingClients in
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
            guard let client = request.client else { return TerminalControlResponse(ok: false, message: "Missing client payload.") }
            let mode = request.attachmentMode ?? .viewer
            do {
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
            guard let clientID = request.clientID else { return TerminalControlResponse(ok: false, message: "Missing client ID.") }
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
            guard let clientID = request.clientID else { return TerminalControlResponse(ok: false, message: "Missing client ID.") }
            do {
                try TerminalSessionPersistence.touchClient(id: clientID, paths: paths, touchedAt: nowISO8601())
                return TerminalControlResponse(ok: true, message: "Refreshed terminal client lease.")
            } catch { return TerminalControlResponse(ok: false, message: String(describing: error)) }
        }

        private func takeover(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard let clientID = request.clientID else { return TerminalControlResponse(ok: false, message: "Missing client ID.") }
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
            guard ownerRequestIsCurrent(request) else { return TerminalControlResponse(ok: false, message: "Only the active owner can send input.") }
            guard var payload = request.inputPayload else { return TerminalControlResponse(ok: false, message: "Missing input payload.") }
            if request.appendNewline { payload.append(0x0A) }
            markLocalOwnerCommandInputOutputResyncPending()
            ptyDriver.sendRawBytes(payload)
            return TerminalControlResponse(ok: true, message: "Sent input.")
        }

        private func key(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else { return TerminalControlResponse(ok: false, message: "Only the active owner can send input.") }
            guard let key = request.key, let bytes = TerminalKeyInput.bytes(for: key) else {
                return TerminalControlResponse(ok: false, message: "Unsupported terminal key.")
            }
            if bytes.contains(0x0D) { markLocalOwnerCommandInputOutputResyncPending() }
            ptyDriver.sendRawBytes(Data(bytes))
            return TerminalControlResponse(ok: true, message: "Sent key.")
        }

        private func clearScreen(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else {
                return TerminalControlResponse(ok: false, message: "Only the active owner can clear the terminal.")
            }
            writeVTRenderer(Data("\u{001B}[H\u{001B}[2J\u{001B}[3J".utf8))
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.clearScreen)
            return TerminalControlResponse(ok: true, message: "Cleared terminal screen and scrollback.")
        }

        private func resize(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else {
                return TerminalControlResponse(ok: false, message: "Only the active owner can resize the terminal.")
            }
            guard let columns = request.columns, let rows = request.rows, columns > 0, rows > 0 else {
                return TerminalControlResponse(ok: false, message: "Missing terminal size.")
            }
            terminalSize = (columns, rows)
            _ = ptyDriver.resizeCellGrid(columns: columns, rows: rows)
            recreateVTRenderer(columns: columns, rows: rows)
            writeRuntimeState(state: .running)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.resize)
            return TerminalControlResponse(ok: true, message: "Resized terminal.")
        }

        private func scroll(_ request: TerminalControlRequest) -> TerminalControlResponse {
            guard ownerRequestIsCurrent(request) else {
                return TerminalControlResponse(ok: false, message: "Only the active owner can scroll the terminal.")
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

        private func ownerRequestIsCurrent(_ request: TerminalControlRequest) -> Bool {
            guard let clientID = request.clientID, activeOwnerClientID() == clientID else { return false }
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

        private func recreateVTRenderer(columns: Int, rows: Int) {
            if let vtSession { spaces_ghostty_vt_session_free(vtSession) }
            vtSession = spaces_ghostty_vt_session_new(UInt16(clamping: columns), UInt16(clamping: rows), Self.maxScrollbackBytes)
            renderUpdateBaseline = nil
            forceNextBroadcastFullRenderUpdate = true
            guard let vtSession, let data = try? Data(contentsOf: URL(fileURLWithPath: paths.outputPath)), !data.isEmpty else { return }
            data.withUnsafeBytes { rawBuffer in
                _ = spaces_ghostty_vt_session_write(vtSession, rawBuffer.bindMemory(to: UInt8.self).baseAddress, rawBuffer.count)
            }
            screenStateRevision &+= 1
        }

        private func writeRuntimeState(state: TerminalSessionState) {
            let liveChildPID = ptyDriver.childPID()
            if let liveChildPID { lastKnownChildPID = liveChildPID }
            let runtimeState = TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(),
                childPID: liveChildPID ?? lastKnownChildPID, state: state, updatedAt: nowISO8601(),
                exitedAt: state.isInteractive ? nil : nowISO8601(), title: launchConfiguration.title,
                workingDirectory: launchConfiguration.workingDirectory, columns: terminalSize.columns, rows: terminalSize.rows,
                foregroundPID: ptyDriver.foregroundPID())
            try? TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
            lastRuntimeState = runtimeState
        }

        private func broadcastCurrentState(reason: String) {
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
