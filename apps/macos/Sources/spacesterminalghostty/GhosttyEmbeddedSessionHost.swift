#if canImport(AppKit) && canImport(GhosttyKit)
    import AppKit
    import Darwin
    import Foundation
    import GhosttyKit
    import spacesterminalcore

    private let ghosttyEmbeddedSessionTraceEnabled = ProcessInfo.processInfo.environment["SPACES_MOBILE_TERMINAL_TRACE"] == "1"

    private func ghosttyEmbeddedSessionTrace(_ sessionID: String, _ message: @autoclosure () -> String) {
        guard ghosttyEmbeddedSessionTraceEnabled else { return }
        fputs("spaces-mobile-terminal-trace t=\(ghosttyEmbeddedSessionTraceSeconds()) mac-host session=\(sessionID) \(message())\n", stderr)
        fflush(stderr)
    }

    private func ghosttyEmbeddedSessionTraceSeconds() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    @MainActor public protocol TerminalGhosttySessionInfoProviding: AnyObject {
        func activeOwnerClientID() -> String?
        var effectiveTitle: String { get }
        var effectiveWorkingDirectory: String { get }
    }

    @MainActor public protocol TerminalGhosttyRendererHosting: AnyObject {
        func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws
        func releaseRendererSurface()
        func setFocused(_ focused: Bool, for clientID: String)
        func focusWindow(_ window: NSWindow?)
        @discardableResult func handleKeyEvent(_ event: NSEvent, for clientID: String) -> Bool
        @discardableResult func synchronizeSurfaceGeometry() -> Bool
        func hasRenderableSurface() -> Bool
        func requestSurfaceRefresh()
        func prepareRenderStateExport()
        func snapshot() -> GhosttyTerminalSnapshot?
        func snapshotText() -> String?
        func sessionSnapshot() -> GhosttyTerminalSnapshot?
        func sessionSnapshotText() -> String?
        func copySelectionToPasteboard() -> Bool
        func pasteClipboardContents() -> Bool
        @discardableResult func sendTextAsPaste(_ text: String) -> Bool
        @discardableResult func performBindingAction(_ action: String) -> Bool
        @discardableResult func sendScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?)
            -> Bool
        @discardableResult func clearScreenAndScrollback() -> Bool
        var debugSearchState: GhosttyTerminalSearchDebugState { get }
        var debugSurfaceRefreshRequestCount: Int { get }
        func debugVisibleSurfaceText() -> String?
    }

    @MainActor public protocol TerminalGhosttySessionHosting: TerminalGhosttySessionInfoProviding, TerminalGhosttyRendererHosting {}

    extension TerminalGhosttyRendererHosting {
        @discardableResult public func sendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool {
            sendScroll(horizontal: horizontal, vertical: vertical, scrollMods: 0, pointerPosition: nil)
        }

        @discardableResult public func sendScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32) -> Bool {
            sendScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: nil)
        }
    }

    /// The daemon-side embedded renderer host, run on the terminal engine actor. It deliberately does
    /// NOT conform to the app-facing `TerminalGhosttyRendererHosting` protocol (which stays `@MainActor`
    /// for `RemoteGhosttySessionHost` and the app UI): the daemon drives it through concrete methods, so
    /// the window-focus / `NSEvent` key-handling members that existed only to satisfy that protocol are
    /// gone (those are the app's responsibility and cannot run on the engine actor).
    @TerminalEngineActor public final class GhosttyHeadlessRendererHost {
        private let sessionDriver: GhosttyEmbeddedTerminalSessionDriver
        private let clearScreenAndScrollbackAction: @TerminalEngineActor () -> Bool
        private var isOwnerClient: (@TerminalEngineActor (String) -> Bool)?
        private var inputActivityHandler: (@TerminalEngineActor (Int) -> Void)?

        init(sessionDriver: GhosttyEmbeddedTerminalSessionDriver, clearScreenAndScrollbackAction: @escaping @TerminalEngineActor () -> Bool) {
            self.sessionDriver = sessionDriver
            self.clearScreenAndScrollbackAction = clearScreenAndScrollbackAction
        }

        func setOwnerClientResolver(_ resolver: @escaping @TerminalEngineActor (String) -> Bool) { isOwnerClient = resolver }

        func setOutputHandler(_ handler: (@Sendable (Data) -> Void)?) { sessionDriver.setOutputHandler(handler) }

        func setInputActivityHandler(_ handler: (@TerminalEngineActor (Int) -> Void)?) { inputActivityHandler = handler }

        func startSessionIfNeeded() throws { try sessionDriver.startIfNeeded() }

        public func requestSurfaceRefresh() { sessionDriver.requestSurfaceRefresh() }

        public func prepareRenderStateExport() {
            sessionDriver.requestSurfaceRefresh()
            GhosttyEmbeddedAppService.shared.tick()
        }

        func sendRawBytes(_ data: Data) {
            sessionDriver.sendRawBytes(data)
            inputActivityHandler?(data.count)
        }

        @discardableResult public func sendTextAsPaste(_ text: String) -> Bool {
            guard !text.isEmpty else { return false }
            sessionDriver.sendTextAsPaste(text)
            inputActivityHandler?(text.utf8.count)
            return true
        }

        func foregroundPID() -> Int32? { sessionDriver.foregroundPID() }

        func childPID() -> Int32? { sessionDriver.childPID() }

        func surfaceCellSize() -> (columns: Int, rows: Int)? { sessionDriver.surfaceCellSize() }

        @discardableResult func resizeCellGrid(columns: Int, rows: Int) -> Bool { sessionDriver.resizeCellGrid(columns: columns, rows: rows) }

        func terminateSession() { sessionDriver.terminate() }

        func setSurfaceFocused(_ focused: Bool) { sessionDriver.setFocused(focused) }

        public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
            _ = client
            _ = mode
            _ = container
            try startSessionIfNeeded()
        }

        public func releaseRendererSurface() {}

        public func setFocused(_ focused: Bool, for clientID: String) { sessionDriver.setFocused(isOwnerClient?(clientID) == true && focused) }

        public func hasRenderableSurface() -> Bool { sessionDriver.snapshot() != nil }

        public func snapshot() -> GhosttyTerminalSnapshot? { sessionDriver.snapshot() }

        public func snapshotText() -> String? { sessionDriver.snapshotText() }

        public func sessionSnapshot() -> GhosttyTerminalSnapshot? { sessionDriver.snapshot() }

        func sessionRenderStateSnapshot() -> GhosttyTerminalSnapshotCapture.CapturedSnapshot? { sessionDriver.renderStateSnapshot() }

        public func sessionSnapshotText() -> String? { sessionDriver.snapshotText() }

        public func copySelectionToPasteboard() -> Bool { false }

        public func pasteClipboardContents() -> Bool {
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
            return sendTextAsPaste(text)
        }

        @discardableResult public func performBindingAction(_ action: String) -> Bool {
            if action == "clear_screen" { return clearScreenAndScrollback() }
            return sessionDriver.performBindingAction(action)
        }

        @discardableResult public func sendScroll(
            horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?
        ) -> Bool { sessionDriver.sendScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition) }

        @discardableResult public func clearScreenAndScrollback() -> Bool { clearScreenAndScrollbackAction() }

        public var debugSearchState: GhosttyTerminalSearchDebugState { .init(isVisible: false, query: "", total: nil, selected: nil) }

        public var debugSurfaceRefreshRequestCount: Int { sessionDriver.debugRefreshRequestCount }

        public func debugVisibleSurfaceText() -> String? { sessionDriver.snapshotText() }
    }

    @TerminalEngineActor public final class GhosttyEmbeddedSessionCore {
        private static let incomingOutputCoalescingInterval: Duration = .milliseconds(4)
        private static let interactiveInputFlushWindowNanoseconds: UInt64 = 750_000_000
        private static let interactiveInputMaximumByteCount = 128

        private final class IncomingOutputBuffer: @unchecked Sendable {
            enum FlushSchedule: Sendable, Equatable {
                case none
                case delayed
                case immediate
            }

            struct DrainedOutput: Sendable {
                let data: Data
                let isInteractive: Bool
            }

            private let lock = NSLock()
            private var pendingData = Data()
            private var flushScheduled = false
            private var immediateFlushScheduled = false
            private var pendingInteractiveOutput = false

            func append(_ data: Data, interactive: Bool) -> FlushSchedule {
                guard !data.isEmpty else { return .none }
                lock.lock()
                defer { lock.unlock() }
                pendingData.append(data)
                pendingInteractiveOutput = pendingInteractiveOutput || interactive
                if flushScheduled {
                    guard interactive, !immediateFlushScheduled else { return .none }
                    immediateFlushScheduled = true
                    return .immediate
                }
                flushScheduled = true
                immediateFlushScheduled = interactive
                return interactive ? .immediate : .delayed
            }

            func drain() -> DrainedOutput {
                lock.lock()
                defer { lock.unlock() }
                let drained = pendingData
                let isInteractive = pendingInteractiveOutput
                pendingData = Data()
                flushScheduled = false
                immediateFlushScheduled = false
                pendingInteractiveOutput = false
                return DrainedOutput(data: drained, isInteractive: isInteractive)
            }
        }

        private final class InteractiveOutputGate: @unchecked Sendable {
            private let lock = NSLock()
            private var deadlineUptimeNanoseconds: UInt64?

            func markActivity(now: UInt64 = DispatchTime.now().uptimeNanoseconds, windowNanoseconds: UInt64) {
                lock.lock()
                deadlineUptimeNanoseconds = now &+ windowNanoseconds
                lock.unlock()
            }

            func consumeIfActive(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard let deadline = deadlineUptimeNanoseconds, now <= deadline else {
                    deadlineUptimeNanoseconds = nil
                    return false
                }
                deadlineUptimeNanoseconds = nil
                return true
            }
        }

        private enum RenderStateExportMode {
            case selfContained
            case streamDeltaAllowed
        }

        public let launchConfiguration: TerminalSessionLaunchConfiguration
        public let paths: TerminalSessionPaths

        private let controlQueue: DispatchQueue
        private let stateStreamQueue: DispatchQueue
        /// Orders every control-request input write (send text/bytes/paste, key) for this session and
        /// spaces submit carriage returns so they read as lone Enter keystrokes; see
        /// `TerminalControlInputSequencer`.
        private let controlInputSequencer = TerminalControlInputSequencer()
        private let sessionDriver: GhosttyEmbeddedTerminalSessionDriver
        private lazy var rendererHostStorage = GhosttyHeadlessRendererHost(
            sessionDriver: sessionDriver, clearScreenAndScrollbackAction: { [weak self] in self?.clearScreenAndScrollback() ?? false })
        private let requestSurfaceRefreshAction: @TerminalEngineActor () -> Void
        /// Per-session 1s runtime-state timer. A `DispatchSourceTimer` on the engine queue replaces the
        /// old `Timer`/`RunLoop.main` pairing — the engine actor's queue has no run loop.
        private var runtimeStateTimer: DispatchSourceTimer?
        private var controlServer: TerminalControlServer?
        private var stateStreamServer: GhosttyRemoteSessionStateStreamServer?
        private var outputHandle: FileHandle?
        private var started = false
        private var didTerminateCurrentRun = false
        private var currentTitle: String?
        private var currentWorkingDirectory: String?
        private var lastObservedProcessWorkingDirectory: String?
        private var lastKnownChildPID: Int32?
        private var lastKnownSurfaceSize: (columns: Int, rows: Int)?
        private var lastSessionStateRevision: UInt64?
        private var lastSessionStateFlags: GhosttyEmbeddedSessionStateChange.Flags?
        private var lastScreenStateRevision: UInt64?
        private var lastExportedScreenStateRevision: UInt64?
        private var lastRenderUpdateBaseline: GhosttyRenderUpdateBaseline?
        private var renderUpdateRevision: UInt64 = 0
        private var forceNextBroadcastFullRenderUpdate = false
        private var lastPersistedRuntimeState: TerminalSessionRuntimeState?
        private var lastRuntimeStateWriteAt: Date?
        private var sessionStartedAt: Date?
        private var foregroundPIDOverrideForTesting: Int32?
        private var foregroundProcessResolver: (Int32) -> TerminalForegroundProcessSnapshot? = { TerminalForegroundProcessInspector.inspect(pid: $0) }
        private var didLogFirstOutput = false
        private let incomingOutputBuffer = IncomingOutputBuffer()
        private let inputStateBroadcastCoalescer = TerminalEngineNextTurnCoalescer()
        private let screenStateChangeBroadcastCoalescer = TerminalEngineNextTurnCoalescer()
        private var pendingScreenStateChangeBroadcastRevision: UInt64?
        private lazy var inputOutputResyncScheduler = GhosttyInputOutputResyncScheduler { [weak self] in
            guard let self else { return }
            self.requestSurfaceRefreshAction()
            GhosttyEmbeddedAppService.shared.tick()
            self.broadcastCurrentState(reason: "input_output")
        }
        private let interactiveOutputGate = InteractiveOutputGate()
        /// In-memory cache of this session's attachment snapshot (`terminal_clients` + `terminal_attachments`
        /// rows), consulted on the per-output-chunk broadcast path in place of a disk read.
        ///
        /// SINGLE-WRITER INVARIANT: the live in-process session core is the sole writer of a live session's
        /// attachment/client rows. Every attach, detach, heartbeat-lease touch, ownership transfer, and
        /// stale-client expiry routes through this core's control handlers, and each invalidates this cache
        /// (attach/detach/transfer/expiry via `postAttachmentStateDidChange()`; heartbeats via
        /// `touchClientLease(_:)`; client upserts via an explicit invalidate). The only writers OUTSIDE a
        /// core — `SpacesdMain.recoverStaleSessions` and `Orchestrator.markReservedWorkspaceTerminalLaunchFailed`
        /// — act exclusively on sessions with NO live core (crashed-prior-daemon sessions, never-started
        /// reservations), so they can never race a live core's cache. The DB stays the durable mirror a fresh
        /// core reseeds from on handoff/restart. Caching this removes a per-output-chunk SQLite connection
        /// open that otherwise saturated the serial terminal-engine executor and starved input under an agent
        /// TUI's continuous output.
        private var cachedAttachmentSnapshot: TerminalSessionAttachmentSnapshot?
        private var ownerEpoch: UInt64 = 0
        /// Set for the brief exec-in-place quiesce window so no late timer/coalescer
        /// turn broadcasts a frame while the session is being handed to the staged
        /// daemon. Cleared on resume (`resumeFromHandoff`) or on the failed-exec
        /// fallback (`resumeInPlaceAfterFailedExec`).
        private var suppressBroadcastsForHandoff = false
        /// Byte offset where renderer-disconnected output begins. On failed handoff the
        /// persisted suffix is streamed back into the existing renderer without being
        /// appended to the transcript again.
        private var handoffTranscriptReplayOffset: UInt64?
        private var lastResizeSerialByClientID: [String: UInt64] = [:]
        private let onSessionClosed: (@TerminalEngineActor (GhosttyEmbeddedSessionCore) -> Void)?

        public init(
            launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
            requestSurfaceRefreshAction: (@TerminalEngineActor () -> Void)? = nil,
            onSessionClosed: (@TerminalEngineActor (GhosttyEmbeddedSessionCore) -> Void)? = nil
        ) {
            self.launchConfiguration = launchConfiguration
            self.paths = paths
            self.onSessionClosed = onSessionClosed
            controlQueue = DispatchQueue(label: "spaces.terminal.session-host.control.\(launchConfiguration.sessionID)")
            stateStreamQueue = DispatchQueue(label: "spaces.terminal.session-host.state-stream.\(launchConfiguration.sessionID)")
            sessionDriver = GhosttyEmbeddedTerminalSessionDriver(launchConfiguration: launchConfiguration)
            self.requestSurfaceRefreshAction = requestSurfaceRefreshAction ?? { [sessionDriver] in sessionDriver.requestSurfaceRefresh() }
            sessionDriver.onActionEvent = { [weak self] event in self?.applyActionEvent(event) }
            sessionDriver.onSessionStateChanged = { [weak self] change in self?.applySessionStateChange(change) }
            sessionDriver.onSurfaceCellSizeChanged = { [weak self] columns, rows in
                guard let self else { return }
                self.lastKnownSurfaceSize = (columns, rows)
                self.refreshRuntimeState(force: true)
            }
            rendererHostStorage.setOwnerClientResolver { [weak self] clientID in self?.isOwner(clientID: clientID) ?? false }
            rendererHostStorage.setInputActivityHandler { [weak self] byteCount in self?.handleOwnerInputActivity(byteCount: byteCount) }
            sessionDriver.onSurfaceClosed = { [weak self] in self?.handleSessionClosed() }
        }

        public func startIfNeeded() throws {
            guard !started else { return }
            let startedAt = Date()
            do {
                try paths.ensureDirectories()
                try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
                try ensureOutputHandle()
                rendererHostStorage.setOutputHandler { [weak self] data in self?.enqueueIncomingOutput(data) }
                rendererHostStorage.setInputActivityHandler { [weak self] byteCount in self?.handleOwnerInputActivity(byteCount: byteCount) }
                didTerminateCurrentRun = false
                started = true
                try rendererHostStorage.startSessionIfNeeded()
                guard started, !didTerminateCurrentRun else { return }
                try startControlServer()
                try startStateStreamServer()
                startRuntimeStateTimer()
                refreshRuntimeState(force: true)
                sessionStartedAt = startedAt
                didLogFirstOutput = false
                broadcastCurrentState(reason: "initial")
                TerminalPerformance.logMetric(
                    "terminal_session_start", target: "session=\(launchConfiguration.sessionID) backend=\(launchConfiguration.backend.rawValue)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
            } catch {
                TerminalPerformance.logMetric(
                    "terminal_session_start", target: "session=\(launchConfiguration.sessionID) backend=\(launchConfiguration.backend.rawValue)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                started = false
                throw error
            }
        }

        public func attachClient(_ client: TerminalClient, mode: TerminalAttachmentMode) throws {
            try startIfNeeded()
            let activeAttachments = (try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []
            let currentAttachment = activeAttachments.first { $0.clientID == client.id }
            let previousOwnerClientID = activeAttachments.first { $0.mode == .owner }?.clientID
            if currentAttachment?.mode != mode {
                try TerminalSessionPersistence.attachClient(
                    sessionID: launchConfiguration.sessionID, client: client, mode: mode, paths: paths,
                    attachedAt: TerminalSessionTimestamp.string(from: Date()))
                if mode == .owner, previousOwnerClientID != client.id { advanceOwnerEpoch(reason: "attach") }
                postAttachmentStateDidChange()
            }
            refreshRuntimeState(force: true)
        }

        public func detach(clientID: String) throws {
            let detachedClientWasOwner = isOwner(clientID: clientID)
            try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: TerminalSessionTimestamp.string(from: Date()))
            var remainingOwnerClientID = activeOwnerClientID()
            if detachedClientWasOwner, remainingOwnerClientID == nil, let localOwnerClientID = activeLocalWindowClientID(excluding: clientID) {
                let transferredAt = TerminalSessionTimestamp.string(from: Date())
                try TerminalSessionPersistence.transferOwnership(
                    sessionID: launchConfiguration.sessionID, newOwnerClientID: localOwnerClientID, paths: paths, transferredAt: transferredAt)
                remainingOwnerClientID = localOwnerClientID
                advanceOwnerEpoch(reason: "detach_transfer")
            }
            if Self.shouldClearFocusAfterDetachingClient(
                detachedClientWasOwner: detachedClientWasOwner, remainingOwnerClientID: remainingOwnerClientID)
            {
                rendererHostStorage.setSurfaceFocused(false)
            }
            if remainingOwnerClientID == nil, rendererHostStorage.hasRenderableSurface() { rendererHostStorage.releaseRendererSurface() }
            postAttachmentStateDidChange()
            refreshRuntimeState(force: true)
        }

        public func isOwner(clientID: String) -> Bool {
            guard isRuntimeInteractiveForControl() else { return false }
            return ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).contains { $0.clientID == clientID && $0.mode == .owner }
        }

        public func activeOwnerClientID() -> String? {
            guard isRuntimeInteractiveForControl() else { return nil }
            return ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).first(where: { $0.mode == .owner })?.clientID
        }

        private func hasActiveAttachments() -> Bool { !((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).isEmpty }

        private func activeLocalWindowClientID(excluding excludedClientID: String) -> String? {
            guard let snapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths) else { return nil }
            let clientsByID = Dictionary(uniqueKeysWithValues: snapshot.clients.map { ($0.id, $0) })
            return snapshot.attachments.filter { $0.detachedAt == nil && $0.clientID != excludedClientID }.compactMap {
                attachment -> TerminalClient? in
                guard let client = clientsByID[attachment.clientID], client.kind == .localWindow, client.disconnectedAt == nil else { return nil }
                return client
            }.first?.id
        }

        public var rendererHost: GhosttyHeadlessRendererHost { rendererHostStorage }
        var isStarted: Bool { started }

        public func terminate() {
            let now = TerminalSessionTimestamp.string(from: Date())
            let childPID = observedChildPID()
            runtimeStateTimer?.cancel()
            runtimeStateTimer = nil
            inputOutputResyncScheduler.cancelForTermination()
            controlServer?.stop()
            controlServer = nil
            TerminalControlServer.removeSocketFileIfPresent(at: paths.controlSocketPath)
            // Flush any output still buffered for the coalesced write before blocking further appends
            // below. A command that produces output and exits immediately (e.g. `seq 1 300`) leaves its
            // final bytes in `incomingOutputBuffer` pending the delayed flush; that flush's `appendOutput`
            // would then be dropped by the `didTerminateCurrentRun` guard, leaving `output.log` empty even
            // though the surface rendered the output. The ended-session scrollback replay reads `output.log`,
            // so without this flush a self-exiting command has no transcript to scroll back through.
            flushPendingIncomingOutputForStateExport()
            didTerminateCurrentRun = true
            started = false
            let exitedState = TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: childPID,
                state: .exited, updatedAt: now, exitedAt: now, title: effectiveTitle, workingDirectory: effectiveWorkingDirectory,
                columns: lastKnownSurfaceSize?.columns, rows: lastKnownSurfaceSize?.rows)
            persistExitedRuntimeState(exitedState)
            try? TerminalSessionPersistence.detachActiveClients(paths: paths, detachedAt: now)
            let finalPayload = currentRemoteSessionState(reason: TerminalRemoteSessionStateReason.terminated, outputByteCount: nil)
            if let finalPayload {
                try? TerminalSessionPersistence.writeRemoteSessionState(finalPayload, paths: paths)
                persistExitedRuntimeState(exitedState)
                broadcastRemoteStatePayload(finalPayload, startedAt: Date(), ownerClient: nil, outputByteCount: nil)
            }
            TerminalSessionNotification.post(.spacesTerminalRuntimeStateDidChange, sessionID: launchConfiguration.sessionID)
            TerminalSessionNotification.post(.spacesTerminalAttachmentStateDidChange, sessionID: launchConfiguration.sessionID)
            TerminalOverviewSignal.post()
            rendererHostStorage.terminateSession()
            try? outputHandle?.synchronize()
            try? outputHandle?.close()
            outputHandle = nil
            stateStreamServer?.stop()
            stateStreamServer = nil
            GhosttyRemoteSessionStateStreamServer.removeSocketFileIfPresent(at: paths.subscriptionSocketPath)
        }

        private func persistExitedRuntimeState(_ state: TerminalSessionRuntimeState) {
            try? TerminalSessionPersistence.writeRuntimeState(state, paths: paths)
            lastPersistedRuntimeState = state
        }

        private func handleSessionClosed() {
            terminate()
            onSessionClosed?(self)
        }

        // MARK: - Exec-in-place handoff

        /// Quiesce this session for the exec-in-place daemon handoff: stop the
        /// per-session timers, suppress broadcasts, and stop the control + state-stream
        /// servers (removing their socket files exactly as `terminate()` does) WITHOUT
        /// detaching clients, killing the child, or freeing the GhosttyKit session. The
        /// PTY read loop keeps draining — first into an in-memory buffer, then straight
        /// to `output.log` — so not a byte is lost across the exec. Returns the handoff
        /// record the staged daemon needs to adopt this session, or nil when there is
        /// nothing live to hand off (the child already exited/closed), in which case the
        /// caller terminates the session normally.
        public func quiesceForHandoff() async throws -> DaemonHandoffSessionRecord? {
            handoffTranscriptReplayOffset = nil
            suppressBroadcastsForHandoff = true
            runtimeStateTimer?.cancel()
            runtimeStateTimer = nil
            inputOutputResyncScheduler.cancelForTermination()

            controlServer?.stop()
            controlServer = nil
            TerminalControlServer.removeSocketFileIfPresent(at: paths.controlSocketPath)
            stateStreamServer?.stop()
            stateStreamServer = nil
            GhosttyRemoteSessionStateStreamServer.removeSocketFileIfPresent(at: paths.subscriptionSocketPath)

            // Nothing live to hand off (child dead/closed): caller terminates normally.
            guard let descriptor = sessionDriver.handoffDescriptorSnapshot() else { return nil }

            // Route further PTY bytes into an in-memory buffer so the read loop never
            // blocks while we drain the main actor and close the durable output handle.
            await sessionDriver.beginHandoffOutputBuffering()

            // The driver has disabled Ghostty's data callback and awaited both the PTY
            // handler boundary and every callback already inside Spaces. All callback
            // bytes are therefore registered in this locked buffer; drain it directly.
            flushPendingIncomingOutputForStateExport()

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
            try sessionDriver.finishHandoffOutputBuffering(appendingTo: paths.outputPath)

            let size = observedSurfaceSize() ?? lastKnownSurfaceSize ?? (columns: 80, rows: 24)
            return DaemonHandoffSessionRecord(
                sessionID: launchConfiguration.sessionID, masterFD: descriptor.masterFD, childPID: descriptor.childPID, columns: size.columns,
                rows: size.rows, ownerEpoch: ownerEpoch, screenStateRevision: lastScreenStateRevision ?? 0,
                appearance: GhosttyEmbeddedAppService.shared.currentAppearance.rawValue)
        }

        /// Holds the PTY sink boundary while the daemon performs its final persistence
        /// validation and `execv`, preventing a direct write from racing after the check.
        public func withValidatedHandoffOutputForExec<T>(_ operation: () throws -> T) throws -> T {
            try sessionDriver.withValidatedHandoffOutputForExec(operation)
        }

        /// Failed-`execv` fallback: `execv` returned, so this same image keeps running and
        /// nothing was freed. Stop the direct-to-file writer, reopen the output handle for
        /// append, restart the per-session servers, and resume timers/broadcasts. This
        /// rebinds the still-live session; it never rebuilds it.
        public func resumeInPlaceAfterFailedExec() async {
            // Freeze the direct writer before reading its persisted range or seeking the
            // replacement FileHandle. PTY output arriving during replay stays buffered.
            sessionDriver.pauseHandoffOutputForFallback()
            if let handoffTranscriptReplayOffset {
                await sessionDriver.replayPersistedHandoffOutput(at: paths.outputPath, startingAt: handoffTranscriptReplayOffset)
            }
            do { try openOutputHandlePreservingTranscript() } catch { fputs("spaces: ghostty handoff transcript reopen failed: \(error)\n", stderr) }
            await sessionDriver.endHandoffOutputBuffering()
            flushPendingIncomingOutputForStateExport()
            self.handoffTranscriptReplayOffset = nil
            suppressBroadcastsForHandoff = false
            do {
                try startControlServer()
                try startStateStreamServer()
            } catch { fputs("spaces: ghostty handoff resume-in-place failed: \(error)\n", stderr) }
            startRuntimeStateTimer()
            refreshRuntimeState(force: true)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.initial)
        }

        /// Resume side of the exec-in-place handoff, run on a freshly built core in the
        /// staged daemon image for a session that survived the exec. Rebuilds the session
        /// by adopting the inherited PTY and replaying output.log at the persisted grid
        /// size, then restarts the servers and republishes a full frame so reconnecting
        /// clients get a self-contained baseline. The process-wide GhosttyKit app runtime
        /// must already be started (its per-process `ghostty_init` guard was wiped by
        /// exec); this ensures it before rebuilding a session.
        public func resumeFromHandoff(_ record: DaemonHandoffSessionRecord) async throws {
            try GhosttyEmbeddedAppService.shared.startIfNeeded()
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            // Preserve output.log: adoptFromHandoff replays it to rebuild the screen.
            try openOutputHandlePreservingTranscript()

            // Apply the recorded appearance BEFORE replay so the rebuilt frames carry the
            // right colors. Appearance is an app-wide (one ghostty_app_t) last-writer-wins
            // setting, applied the same way an attaching client applies it.
            if let appearanceRaw = record.appearance, let appearance = ThemeAppearance(rawValue: appearanceRaw) {
                GhosttyEmbeddedAppService.shared.applyColorScheme(appearance)
            }

            rendererHostStorage.setOutputHandler { [weak self] data in self?.enqueueIncomingOutput(data) }
            rendererHostStorage.setInputActivityHandler { [weak self] byteCount in self?.handleOwnerInputActivity(byteCount: byteCount) }
            didTerminateCurrentRun = false
            started = true
            suppressBroadcastsForHandoff = false

            do {
                try await sessionDriver.adoptFromHandoff(
                    masterFD: record.masterFD, childPID: record.childPID, columns: record.columns, rows: record.rows, outputLogPath: paths.outputPath)
            } catch {
                started = false
                throw error
            }

            ownerEpoch = record.ownerEpoch
            // Advance past the recorded revision and force the first broadcast to a full
            // render update so reconnecting clients rebuild from a self-contained baseline.
            lastScreenStateRevision = record.screenStateRevision &+ 1
            lastRenderUpdateBaseline = nil
            forceNextBroadcastFullRenderUpdate = true
            lastKnownSurfaceSize = (columns: record.columns, rows: record.rows)

            try startControlServer()
            try startStateStreamServer()
            startRuntimeStateTimer()
            sessionStartedAt = Date()
            didLogFirstOutput = false
            refreshRuntimeState(force: true)
            broadcastCurrentState(reason: TerminalRemoteSessionStateReason.initial)
        }

        var debugOwnerEpoch: UInt64 { ownerEpoch }

        public func childPID() -> Int32? { observedChildPID() }
        public var effectiveTitle: String { currentTitle ?? launchConfiguration.title }
        // Prefer the live cwd observed from the foreground/child process (cached by refreshRuntimeState)
        // so the working directory clients see converges on reality even when the shell never reports a
        // new PWD through Ghostty shell integration (OSC 7). currentWorkingDirectory (the PWD-action
        // value) remains the next fallback, then the launch directory. This property is read on the
        // per-render broadcast path, so it only reads the cached value — the proc lookup that fills the
        // cache runs on the slower runtime-state refresh path.
        public var effectiveWorkingDirectory: String {
            lastObservedProcessWorkingDirectory ?? currentWorkingDirectory ?? launchConfiguration.workingDirectory
        }

        private func startControlServer() throws {
            let controlServer = TerminalControlServer(socketPath: paths.controlSocketPath, queue: controlQueue) { [weak self] request in
                // The control server runs this on its own transport queue; bridge synchronously onto the
                // terminal engine actor (never the main actor) so a blocked main actor can't stall control.
                TerminalEngineActor.runSynchronously {
                    guard let self else {
                        return TerminalControlResponse(ok: false, message: "Terminal session is shutting down.", errorCode: .shuttingDown)
                    }
                    return self.handleControlRequest(request)
                }
            }
            try controlServer.start()
            self.controlServer = controlServer
        }

        private func startStateStreamServer() throws {
            let stateStreamServer = GhosttyRemoteSessionStateStreamServer(
                socketPath: paths.subscriptionSocketPath, queue: stateStreamQueue,
                initialStateProvider: { [weak self] in
                    TerminalEngineActor.runSynchronously {
                        // Arm the forced full frame for EVERY subscriber whose unicast initial
                        // carries no render update, not just the first connection: one-shot
                        // `.state` reads share this socket, so "no existing clients" is routinely
                        // false when the real subscriber connects, and without a full-frame
                        // baseline its deltas can never apply (the pane never becomes renderable).
                        self?.currentRemoteSessionState(
                            reason: TerminalRemoteSessionStateReason.initial, outputByteCount: nil, exportMode: .selfContained,
                            markNextBroadcastFullWhenMissingRenderUpdate: true)
                    }
                })
            try stateStreamServer.start()
            self.stateStreamServer = stateStreamServer
        }

        public func handleControlRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let command = request.commandValue
            trace(
                "control_request command=\(command.name) client=\(request.clientID ?? request.client?.id ?? "nil") target_session=\(launchConfiguration.sessionID)"
            )
            return switch command {
            case .attach: controlResponseForAttachRequest(request)
            case .detach: controlResponseForDetachRequest(request)
            case .heartbeat: controlResponseForHeartbeatRequest(request)
            case .send: controlResponseForSendRequest(request)
            case .key: controlResponseForKeyRequest(request)
            case .clearScreen: controlResponseForClearScreenRequest(request)
            case .takeover: controlResponseForTakeoverRequest(request)
            case .resize: controlResponseForResizeRequest(request)
            case .scroll: controlResponseForScrollRequest(request)
            case .setAppearance: controlResponseForSetAppearanceRequest(request)
            case .unsupported(let name): TerminalControlResponse(ok: false, message: "Unsupported terminal command '\(name)'.")
            }
        }

        private func ownerRequestRejection(for request: TerminalControlRequest, commandName: String, startedAt: Date) -> TerminalControlResponse? {
            guard let clientID = request.clientID else { return nil }
            guard isOwner(clientID: clientID) else {
                TerminalPerformance.logMetric(
                    "terminal_control_\(commandName)", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "owner=stale")
                return TerminalControlResponse(
                    ok: false, message: "Only the active owner can \(commandName) the terminal.", errorCode: .ownershipRejected)
            }
            guard let requestedOwnerEpoch = request.ownerEpoch else { return nil }
            guard requestedOwnerEpoch == ownerEpoch else {
                TerminalPerformance.logMetric(
                    "terminal_control_\(commandName)", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false,
                    detail: "owner_epoch=\(requestedOwnerEpoch) current_owner_epoch=\(ownerEpoch)")
                return TerminalControlResponse(
                    ok: false, message: "Ignoring stale owner epoch \(requestedOwnerEpoch); current owner epoch is \(ownerEpoch).",
                    errorCode: .ownershipRejected)
            }
            return nil
        }

        private func staleResizeSerialRejection(for request: TerminalControlRequest, startedAt: Date) -> TerminalControlResponse? {
            guard let clientID = request.clientID, let resizeSerial = request.resizeSerial else { return nil }
            guard let lastResizeSerial = lastResizeSerialByClientID[clientID], resizeSerial <= lastResizeSerial else { return nil }
            TerminalPerformance.logMetric(
                "terminal_control_resize", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false,
                detail: "resize_serial=\(resizeSerial) last_resize_serial=\(lastResizeSerial)")
            return TerminalControlResponse(
                ok: false, message: "Ignoring stale resize serial \(resizeSerial); latest accepted serial is \(lastResizeSerial).",
                errorCode: .ownershipRejected)
        }

        private func recordAcceptedResizeSerial(from request: TerminalControlRequest) {
            guard let clientID = request.clientID, let resizeSerial = request.resizeSerial else { return }
            lastResizeSerialByClientID[clientID] = resizeSerial
        }

        private func advanceOwnerEpoch(reason: String) {
            ownerEpoch &+= 1
            lastResizeSerialByClientID.removeAll(keepingCapacity: true)
            lastRenderUpdateBaseline = nil
            trace("owner_epoch_advanced reason=\(reason) owner_epoch=\(ownerEpoch) owner=\(activeOwnerClientID() ?? "nil")")
        }

        private func controlResponseForAttachRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            guard let client = request.client else {
                TerminalPerformance.logMetric(
                    "terminal_control_attach", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: "Missing client payload.", errorCode: .invalidArgument)
            }
            let mode = request.attachmentMode ?? .viewer
            let attachedAt = nowISO8601()
            let authoritativeClient = Self.clientForAttachLease(client, attachedAt: attachedAt)
            do {
                // Adopt the attaching client's light/dark appearance. The Ghostty color scheme is
                // app-scoped (one ghostty_app_t per daemon), so this re-themes every live surface in
                // the daemon on a last-writer-wins basis. The io thread applies the colors
                // asynchronously, so we deliberately do NOT broadcast inline here: an immediate frame
                // would still carry the pre-retheme colors. Instead we arm forceNextBroadcastFull
                // below and let the recolored screen reach subscribers through the existing screen
                // state-change broadcast that Ghostty triggers once the retheme lands (and the
                // always-fresh initial-frame export for subscribers that connect afterwards).
                let appearanceChanged = request.appearance.map { GhosttyEmbeddedAppService.shared.applyColorScheme($0) } ?? false
                let previousOwnerClientID = activeOwnerClientID()
                try TerminalSessionPersistence.upsertClient(authoritativeClient, paths: paths)
                invalidateAttachmentSnapshotCache()
                let currentAttachment = try TerminalSessionPersistence.activeAttachments(paths: paths).first { $0.clientID == authoritativeClient.id }
                if currentAttachment?.mode != mode {
                    try TerminalSessionPersistence.attachClient(
                        sessionID: launchConfiguration.sessionID, client: authoritativeClient, mode: mode, paths: paths, attachedAt: attachedAt)
                    if mode == .owner, previousOwnerClientID != authoritativeClient.id { advanceOwnerEpoch(reason: "control_attach") }
                    postAttachmentStateDidChange()
                }
                refreshRuntimeState(force: true)
                // Set after the attachment broadcast above so the recolored screen (delivered by the
                // next broadcast, once Ghostty finishes the async retheme) is a self-contained full
                // frame rather than a color-only delta from a stale baseline. There is no host-side
                // screen revision to bump here: lastScreenStateRevision tracks Ghostty's own
                // revisions, which the retheme advances on its own.
                if appearanceChanged { forceNextBroadcastFullRenderUpdate = true }
                TerminalPerformance.logMetric(
                    "terminal_control_attach", target: "session=\(launchConfiguration.sessionID) client=\(authoritativeClient.id)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "mode=\(mode.rawValue)")
                return TerminalControlResponse(ok: true, message: "Attached \(mode.rawValue) client.")
            } catch {
                TerminalPerformance.logMetric(
                    "terminal_control_attach", target: "session=\(launchConfiguration.sessionID) client=\(authoritativeClient.id)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "mode=\(mode.rawValue)")
                return TerminalControlResponse(ok: false, message: String(describing: error))
            }
        }

        private func controlResponseForSetAppearanceRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            touchClientLease(request.clientID)
            // Appearance is a per-client view preference on a shared session with last-writer-wins
            // semantics, so it is deliberately NOT owner-gated: viewers flip their own app appearance
            // and every client should be able to re-theme the terminal it is watching.
            guard let appearance = request.appearance else {
                TerminalPerformance.logMetric(
                    "terminal_control_set_appearance", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: "Missing appearance.", errorCode: .invalidArgument)
            }
            // Re-theme every live surface app-wide (one ghostty_app_t per daemon). The io thread
            // applies the colors asynchronously, so we do NOT broadcast inline here: an immediate
            // frame would still carry the pre-retheme colors. Instead arm forceNextBroadcastFull so
            // the recolored screen reaches subscribers as a self-contained full frame through the
            // screen state-change broadcast Ghostty triggers once the retheme lands.
            let appearanceChanged = GhosttyEmbeddedAppService.shared.applyColorScheme(appearance)
            if appearanceChanged { forceNextBroadcastFullRenderUpdate = true }
            TerminalPerformance.logMetric(
                "terminal_control_set_appearance", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
                detail: "appearance=\(appearance.rawValue) changed=\(appearanceChanged ? 1 : 0)")
            return TerminalControlResponse(
                ok: true,
                message: appearanceChanged ? "Applied \(appearance.rawValue) appearance." : "Terminal already matches the requested appearance.")
        }

        private func controlResponseForDetachRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard let clientID = request.clientID else {
                TerminalPerformance.logMetric(
                    "terminal_control_detach", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: "Missing client ID.", errorCode: .invalidArgument)
            }
            do {
                let hasActiveAttachment = try TerminalSessionPersistence.activeAttachments(paths: paths).contains { $0.clientID == clientID }
                if hasActiveAttachment { try detach(clientID: clientID) }
                TerminalPerformance.logMetric(
                    "terminal_control_detach", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
                return TerminalControlResponse(ok: true, message: "Detached terminal client.")
            } catch {
                TerminalPerformance.logMetric(
                    "terminal_control_detach", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: String(describing: error))
            }
        }

        private func controlResponseForHeartbeatRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard let clientID = request.clientID else {
                TerminalPerformance.logMetric(
                    "terminal_control_heartbeat", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: "Missing client ID.", errorCode: .invalidArgument)
            }
            do {
                try TerminalSessionPersistence.touchClient(id: clientID, paths: paths, touchedAt: nowISO8601())
                invalidateAttachmentSnapshotCache()
                TerminalPerformance.logMetric(
                    "terminal_control_heartbeat", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
                return TerminalControlResponse(ok: true, message: "Refreshed terminal client lease.")
            } catch {
                TerminalPerformance.logMetric(
                    "terminal_control_heartbeat", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: String(describing: error))
            }
        }

        private func controlResponseForSendRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            touchClientLease(request.clientID)
            if let rejection = ownerRequestRejection(for: request, commandName: "send", startedAt: startedAt) { return rejection }
            if request.asPaste {
                guard var text = request.text, request.bytes == nil else {
                    return TerminalControlResponse(ok: false, message: "Paste input requires text payload.", errorCode: .invalidArgument)
                }
                if request.appendNewline { text.append("\n") }
                guard !text.isEmpty else { return TerminalControlResponse(ok: false, message: "Missing input payload.", errorCode: .invalidArgument) }
                markLocalOwnerCommandInputOutputResyncPending()
                let pasteText = text
                controlInputSequencer.enqueueWrite { [weak self] in
                    await TerminalEngineActor.run { _ = self?.rendererHostStorage.sendTextAsPaste(pasteText) }
                }
                TerminalPerformance.logMetric(
                    "terminal_control_send", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "bytes=\(text.utf8.count)")
                return TerminalControlResponse(ok: true, message: "Sent input.")
            } else {
                guard let payload = request.inputPayload else {
                    return TerminalControlResponse(ok: false, message: "Missing input payload.", errorCode: .invalidArgument)
                }
                markLocalOwnerCommandInputOutputResyncPending()
                // Submit-safe send: a text payload with appendNewline is a "submit" (type this, press Enter).
                // Agent TUIs (Claude Code, Codex, OpenCode) treat text bytes immediately followed by the
                // carriage return, arriving in one PTY read burst, as a pasted block and leave it
                // unsubmitted in the composer. So the text (which may itself contain newlines, e.g. a
                // multi-line notification) is written first, and the CR (0x0D) is written as a separate
                // burst after a delay (see `TerminalControlInputSequencer`) so the TUI reads it as a
                // distinct Enter keystroke that submits. Enter is a CR because shells and Claude Code
                // accept LF or CR while Codex and OpenCode submit only on CR. An empty text with
                // appendNewline is a bare Enter (e.g. answering a TUI dialog): send the CR immediately, there
                // is nothing to separate. Byte payloads are opaque input rather than composer text, so they
                // keep the single inline write. Writes land shortly after the response through the
                // sequencer, which keeps the text+CR pair ordered against every later input write.
                let isTextPayload = request.bytes == nil
                if request.appendNewline, isTextPayload, !payload.isEmpty {
                    enqueueControlInputWrite(payload)
                    enqueueControlSubmitCarriageReturn()
                } else {
                    var bytes = payload
                    if request.appendNewline { bytes.append(0x0D) }
                    enqueueControlInputWrite(bytes)
                }
                TerminalPerformance.logMetric(
                    "terminal_control_send", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "bytes=\(payload.count)")
                return TerminalControlResponse(ok: true, message: "Sent input.")
            }
        }

        private func enqueueControlInputWrite(_ bytes: Data) {
            controlInputSequencer.enqueueWrite { [weak self] in await TerminalEngineActor.run { self?.rendererHostStorage.sendRawBytes(bytes) } }
        }

        private func enqueueControlSubmitCarriageReturn() {
            controlInputSequencer.enqueueSubmitCarriageReturn { [weak self] in
                await TerminalEngineActor.run { self?.rendererHostStorage.sendRawBytes(Data([0x0D])) }
            }
        }

        private func controlResponseForKeyRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            touchClientLease(request.clientID)
            if let rejection = ownerRequestRejection(for: request, commandName: "key", startedAt: startedAt) { return rejection }
            if let key = request.key, TerminalKeyInput.hostAction(for: key) == .clearScreenAndScrollback {
                return controlResponseForClearScreenRequest(request, startedAt: startedAt, touchClient: false)
            }
            guard let key = request.key, let bytes = TerminalKeyInput.bytes(for: key) else {
                TerminalPerformance.logMetric(
                    "terminal_control_key", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: "Unsupported terminal key.", errorCode: .invalidArgument)
            }
            if bytes.contains(0x0D) { markLocalOwnerCommandInputOutputResyncPending() }
            enqueueControlInputWrite(Data(bytes))
            TerminalPerformance.logMetric(
                "terminal_control_key", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "key=\(key)")
            return TerminalControlResponse(ok: true, message: "Sent key.")
        }

        private func controlResponseForClearScreenRequest(_ request: TerminalControlRequest, startedAt: Date = Date(), touchClient: Bool = true)
            -> TerminalControlResponse
        {
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            if touchClient, let clientID = request.clientID {
                touchClientLease(clientID)
            }
            if let rejection = ownerRequestRejection(for: request, commandName: "clear", startedAt: startedAt) { return rejection }
            let cleared = rendererHostStorage.clearScreenAndScrollback()
            if cleared { broadcastCurrentState(reason: TerminalRemoteSessionStateReason.clearScreen) }
            TerminalPerformance.logMetric(
                "terminal_control_clear_screen", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: cleared)
            return TerminalControlResponse(
                ok: cleared, message: cleared ? "Cleared terminal screen and scrollback." : "Unable to clear terminal screen.")
        }

        private func controlResponseForScrollRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            touchClientLease(request.clientID)
            if let rejection = ownerRequestRejection(for: request, commandName: "scroll", startedAt: startedAt) { return rejection }
            let horizontal = CGFloat(request.scrollHorizontal ?? 0)
            let vertical = CGFloat(request.scrollVertical ?? 0)
            let scrollMods = request.scrollMods ?? 0
            let pointerPosition: TerminalScrollPointerPosition?
            switch (request.scrollPointerX, request.scrollPointerY, request.scrollPointerMods) {
            case (nil, nil, nil): pointerPosition = nil
            case (let x?, let y?, let mods):
                let position = TerminalScrollPointerPosition(x: x, y: y, mods: mods ?? 0)
                guard position.isValid else {
                    return TerminalControlResponse(ok: false, message: "Invalid terminal scroll pointer position.", errorCode: .invalidArgument)
                }
                pointerPosition = position
            default:
                return TerminalControlResponse(
                    ok: false, message: "Terminal scroll pointer coordinates must be provided together.", errorCode: .invalidArgument)
            }
            guard horizontal != 0 || vertical != 0 || scrollMods != 0 else {
                return TerminalControlResponse(ok: true, message: "Ignored zero scroll delta.")
            }
            guard horizontal != 0 || vertical != 0 else { return TerminalControlResponse(ok: true, message: "Ignored zero scroll delta.") }
            if let ownerClient = activeOwnerClient() {
                logMobileTakeoverPerformance(
                    name: "owner_input_activity", attributes: ["owner_kind": ownerClient.kind.rawValue, "interactive": "1", "input_kind": "scroll"])
            }
            let scrolled = rendererHostStorage.sendScroll(
                horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition)
            if scrolled { broadcastCurrentState(reason: TerminalRemoteSessionStateReason.scroll) }
            TerminalPerformance.logMetric(
                "terminal_control_scroll", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: scrolled)
            return TerminalControlResponse(ok: scrolled, message: scrolled ? "Scrolled terminal." : "Unable to scroll terminal.")
        }

        private func controlResponseForTakeoverRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            guard let clientID = request.clientID else {
                return TerminalControlResponse(ok: false, message: "Missing client ID.", errorCode: .invalidArgument)
            }
            do {
                touchClientLease(clientID)
                flushPendingIncomingOutputForStateExport()
                let previousOwnerClientID = activeOwnerClientID()
                try TerminalSessionPersistence.transferOwnership(
                    sessionID: launchConfiguration.sessionID, newOwnerClientID: clientID, paths: paths,
                    transferredAt: TerminalSessionTimestamp.string(from: Date()))
                if previousOwnerClientID != clientID { advanceOwnerEpoch(reason: "takeover") }
                Task { @TerminalEngineActor [weak self] in
                    guard let self else { return }
                    self.postAttachmentStateDidChange()
                    self.refreshRuntimeState(force: true)
                }
                TerminalPerformance.logMetric(
                    "terminal_control_takeover", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
                return TerminalControlResponse(ok: true, message: "Transferred terminal ownership.")
            } catch {
                TerminalPerformance.logMetric(
                    "terminal_control_takeover", target: "session=\(launchConfiguration.sessionID) client=\(clientID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                return TerminalControlResponse(ok: false, message: String(describing: error))
            }
        }

        private func controlResponseForResizeRequest(_ request: TerminalControlRequest) -> TerminalControlResponse {
            let startedAt = Date()
            guard isRuntimeInteractiveForControl() else {
                return TerminalControlResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)
            }
            touchClientLease(request.clientID)
            if let rejection = ownerRequestRejection(for: request, commandName: "resize", startedAt: startedAt) { return rejection }
            if let rejection = staleResizeSerialRejection(for: request, startedAt: startedAt) { return rejection }
            guard let columns = request.columns, let rows = request.rows, columns > 0, rows > 0 else {
                return TerminalControlResponse(ok: false, message: "Missing terminal size.", errorCode: .invalidArgument)
            }
            let currentSize = observedSurfaceSize()
            if currentSize?.columns == columns, currentSize?.rows == rows {
                trace(
                    "resize_request_noop client=\(request.clientID ?? "nil") columns=\(columns) rows=\(rows) runtime=\(traceSize(currentSize)) owner=\(activeOwnerClientID() ?? "nil")"
                )
                TerminalPerformance.logMetric(
                    "terminal_control_resize", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "columns=\(columns) rows=\(rows) noop=1")
                recordAcceptedResizeSerial(from: request)
                return TerminalControlResponse(ok: true, message: "Terminal already matches the requested size.")
            }
            trace(
                "resize_request client=\(request.clientID ?? "nil") columns=\(columns) rows=\(rows) runtime_before=\(traceSize(currentSize)) owner=\(activeOwnerClientID() ?? "nil")"
            )
            let resized = rendererHostStorage.resizeCellGrid(columns: columns, rows: rows)
            refreshRuntimeState(force: true)
            trace("resize_request_result resized=\(resized ? 1 : 0) runtime_after=\(traceSize(observedSurfaceSize()))")
            TerminalPerformance.logMetric(
                "terminal_control_resize", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: resized, detail: "columns=\(columns) rows=\(rows)")
            if resized {
                recordAcceptedResizeSerial(from: request)
                broadcastCurrentState(reason: "resize")
            }
            return TerminalControlResponse(ok: resized, message: resized ? "Resized terminal." : "Unable to match the requested terminal size.")
        }

        private func startRuntimeStateTimer() {
            runtimeStateTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: TerminalEngineActor.shared.queue)
            timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
            timer.setEventHandler { [weak self] in
                // Fires on the engine queue (the timer's queue), so assume the engine isolation.
                TerminalEngineActor.assumeIsolated {
                    guard let self, self.started else { return }
                    self.expireStaleRemoteClientsIfNeeded()
                    self.refreshRuntimeState(force: false)
                }
            }
            timer.resume()
            runtimeStateTimer = timer
        }

        private func refreshRuntimeState(force: Bool) {
            guard !didTerminateCurrentRun else { return }
            guard started || !currentRuntimeStateIsExited() else { return }
            let now = Date()
            let liveChildPID = rendererHostStorage.childPID()
            if let liveChildPID { lastKnownChildPID = liveChildPID }
            let childPID = liveChildPID ?? lastKnownChildPID
            let foregroundPID = observedForegroundPID()
            if started, liveChildPID == nil, let lastKnownChildPID, !hasActiveAttachments(), !Self.isProcessAlive(pid: lastKnownChildPID) {
                handleSessionClosed()
                return
            }
            let foregroundProcess = foregroundPID.flatMap(foregroundProcessResolver)
            let foregroundAgent = foregroundProcess.flatMap(TerminalForegroundProcessInspector.classify)
            // Refresh the cached live cwd here (off the per-render broadcast path) so effectiveWorkingDirectory
            // publishes the process's real directory even when the shell never emits an OSC 7 PWD report.
            if let liveWorkingDirectory = Self.liveProcessWorkingDirectory(foregroundPID: foregroundPID, childPID: childPID) {
                lastObservedProcessWorkingDirectory = liveWorkingDirectory
            }
            let state = TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(),
                childPID: childPID ?? lastKnownChildPID, state: .running, updatedAt: TerminalSessionTimestamp.string(from: now),
                title: effectiveTitle, workingDirectory: effectiveWorkingDirectory, columns: observedSurfaceSize()?.columns,
                rows: observedSurfaceSize()?.rows, foregroundPID: foregroundProcess?.pid, foregroundExecutablePath: foregroundProcess?.executablePath,
                foregroundExecutableName: foregroundProcess?.executableName, foregroundArgv: foregroundProcess?.argv,
                foregroundDetectedAgentKind: foregroundAgent?.detectedAgentKind, foregroundDisplayLabel: foregroundAgent?.displayLabel,
                foregroundDisplayCommand: foregroundAgent?.displayCommand)
            let shouldPersist = force || shouldPersistRuntimeState(state, now: now)
            guard shouldPersist else { return }
            let previousSignature = lastPersistedRuntimeState.map(runtimeStateSignature(for:))
            let nextSignature = runtimeStateSignature(for: state)
            try? TerminalSessionPersistence.writeRuntimeState(state, paths: paths)
            lastPersistedRuntimeState = state
            lastRuntimeStateWriteAt = now
            if previousSignature != nextSignature { postRuntimeStateDidChange() }
        }

        private func currentRuntimeStateIsExited() -> Bool {
            if lastPersistedRuntimeState?.state == .exited { return true }
            return (try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.state == .exited
        }

        @discardableResult func expireStaleRemoteClientsIfNeeded(now: Date = Date()) -> [String] {
            guard let staleClientIDs = try? TerminalSessionPersistence.staleRemoteClientIDs(paths: paths, now: now), !staleClientIDs.isEmpty else {
                return []
            }
            let activeAttachmentsBeforeExpiry = (try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []
            let staleClientIDSet = Set(staleClientIDs)
            let detachedClientWasOwner = activeAttachmentsBeforeExpiry.contains {
                $0.mode == .owner && $0.detachedAt == nil && staleClientIDSet.contains($0.clientID)
            }
            let detachedAt = TerminalSessionTimestamp.string(from: now)
            for clientID in staleClientIDs { try? TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: detachedAt) }
            var remainingOwnerClientID = activeOwnerClientID()
            if detachedClientWasOwner, remainingOwnerClientID == nil, let localOwnerClientID = activeLocalWindowClientID(excluding: "") {
                try? TerminalSessionPersistence.transferOwnership(
                    sessionID: launchConfiguration.sessionID, newOwnerClientID: localOwnerClientID, paths: paths, transferredAt: detachedAt)
                remainingOwnerClientID = localOwnerClientID
                advanceOwnerEpoch(reason: "stale_client_transfer")
            }
            if Self.shouldClearFocusAfterDetachingClient(detachedClientWasOwner: false, remainingOwnerClientID: remainingOwnerClientID) {
                rendererHostStorage.setSurfaceFocused(false)
            }
            if remainingOwnerClientID == nil, rendererHostStorage.hasRenderableSurface() { rendererHostStorage.releaseRendererSurface() }
            postAttachmentStateDidChange()
            refreshRuntimeState(force: true)
            return staleClientIDs
        }

        @discardableResult private func appendOutput(_ data: Data, interactiveResync: Bool = false, shouldBroadcastState: Bool = true) -> Bool {
            guard !didTerminateCurrentRun else { return false }
            let startedAt = Date()
            do {
                let outputHandle = try ensureOutputHandle()
                try outputHandle.write(contentsOf: data)
                let outputEndByteOffset = (try? outputHandle.seekToEnd()).map(Self.clampedInt)
                requestSurfaceRefreshAction()
                GhosttyEmbeddedAppService.shared.tick()
                postOutputDidChange(
                    data: data, outputEndByteOffset: outputEndByteOffset, interactiveResync: interactiveResync,
                    shouldBroadcastState: shouldBroadcastState)
                TerminalPerformance.logMetric(
                    "terminal_output_write", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "bytes=\(data.count)")
                if !didLogFirstOutput, !data.isEmpty {
                    didLogFirstOutput = true
                    if let sessionStartedAt {
                        TerminalPerformance.logMetric(
                            "terminal_first_output", target: "session=\(launchConfiguration.sessionID)",
                            elapsedMS: TerminalPerformance.elapsedMS(since: sessionStartedAt), success: true, detail: "bytes=\(data.count)")
                    }
                }
                return true
            } catch {
                TerminalPerformance.logMetric(
                    "terminal_output_write", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "bytes=\(data.count)")
                fputs("spaces: ghostty output write failed: \(error)\n", stderr)
                return false
            }
        }

        /// Keeps the renderer mutation replayable. The marker enters the same locked
        /// coalescing buffer as PTY callbacks, preserving its byte order with concurrent
        /// output before the buffer is drained synchronously.
        private func clearScreenAndScrollback() -> Bool {
            guard sessionDriver.clearScreenAndScrollback() else { return false }
            _ = incomingOutputBuffer.append(GhosttyTerminalTranscriptMutation.clearScreenAndScrollback, interactive: false)
            let outputThroughClear = incomingOutputBuffer.drain()
            return appendOutput(outputThroughClear.data, interactiveResync: outputThroughClear.isInteractive, shouldBroadcastState: false)
        }

        @discardableResult private func ensureOutputHandle() throws -> FileHandle {
            if let outputHandle { return outputHandle }
            FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
            FileManager.default.createFile(atPath: paths.serviceLogPath, contents: nil)
            let createdHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
            try createdHandle.seekToEnd()
            outputHandle = createdHandle
            return createdHandle
        }

        /// Opens the durable output handle for append WITHOUT truncating any existing
        /// transcript, for the handoff resume paths. `resumeFromHandoff` replays output.log
        /// to rebuild the screen and `resumeInPlaceAfterFailedExec` continues the same
        /// transcript, so both must keep the existing bytes — unlike `ensureOutputHandle`,
        /// whose `createFile(contents: nil)` recreates (and thus empties) the log for a
        /// fresh start. Creating the file only when absent leaves any existing history in
        /// place; `seekToEnd` positions the handle to append and re-derive the byte count.
        private func openOutputHandlePreservingTranscript() throws {
            guard outputHandle == nil else { return }
            if !FileManager.default.fileExists(atPath: paths.outputPath) { FileManager.default.createFile(atPath: paths.outputPath, contents: nil) }
            if !FileManager.default.fileExists(atPath: paths.serviceLogPath) {
                FileManager.default.createFile(atPath: paths.serviceLogPath, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
            try handle.seekToEnd()
            outputHandle = handle
        }

        private func transcriptByteCount() throws -> UInt64 {
            guard FileManager.default.fileExists(atPath: paths.outputPath) else { return 0 }
            let attributes = try FileManager.default.attributesOfItem(atPath: paths.outputPath)
            guard let size = attributes[.size] as? NSNumber else { throw POSIXError(.EIO) }
            return size.uint64Value
        }

        func applyActionEvent(_ event: GhosttyActionEvent) {
            switch event {
            case .setTitle(let title): currentTitle = Self.normalizedSessionMetadataValue(title)
            case .setWorkingDirectory(let path): currentWorkingDirectory = Self.normalizedSessionMetadataValue(path)
            case .openURL(_, let value):
                // GhosttyTerminalLinkOpener.open uses NSWorkspace (main-only). The daemon is headless so
                // this is effectively a no-op there, but keep it correct via an async engine→main hop
                // rather than blocking the engine actor on the main actor.
                Task { @MainActor in _ = GhosttyTerminalLinkOpener.open(value) }
                return
            case .mouseOverLink, .startSearch, .endSearch, .searchTotal, .searchSelected: return
            }
            postSessionMetadataDidChange()
            refreshRuntimeState(force: true)
        }

        func applySessionStateChange(_ change: GhosttyEmbeddedSessionStateChange) {
            lastSessionStateRevision = max(lastSessionStateRevision ?? change.revision, change.revision)
            lastSessionStateFlags = change.flags
            if change.flags.contains(.screen) { lastScreenStateRevision = max(lastScreenStateRevision ?? change.revision, change.revision) }
            if change.flags.contains(.screen) {
                requestSurfaceRefreshAction()
                logMobileTakeoverPerformance(
                    name: "state_change", attributes: ["revision": String(change.revision), "flags": String(change.flags.rawValue)])
                scheduleScreenStateChangeBroadcast(revision: change.revision)
            }
            var metadataChanged = false

            if change.flags.contains(.title) {
                let nextTitle = Self.normalizedSessionMetadataValue(change.title)
                if currentTitle != nextTitle {
                    currentTitle = nextTitle
                    metadataChanged = true
                }
            }

            if change.flags.contains(.workingDirectory) {
                let nextWorkingDirectory = Self.normalizedSessionMetadataValue(change.workingDirectory)
                if currentWorkingDirectory != nextWorkingDirectory {
                    currentWorkingDirectory = nextWorkingDirectory
                    metadataChanged = true
                }
            }

            if metadataChanged { postSessionMetadataDidChange() }

            if change.flags.contains(.foregroundProcess) { _ = observedChildPID() }
            if change.flags.contains(.size), let size = rendererHostStorage.surfaceCellSize() { lastKnownSurfaceSize = size }

            if metadataChanged || !change.flags.intersection(.runtimeState).isEmpty { refreshRuntimeState(force: true) }
        }

        private func observedChildPID() -> Int32? {
            if let childPID = rendererHostStorage.childPID() {
                lastKnownChildPID = childPID
                return childPID
            }
            return lastKnownChildPID
        }

        private func observedForegroundPID() -> Int32? { foregroundPIDOverrideForTesting ?? rendererHostStorage.foregroundPID() }

        private static func liveProcessWorkingDirectory(foregroundPID: Int32?, childPID: Int32?) -> String? {
            if let foregroundPID, let cwd = TerminalForegroundProcessInspector.workingDirectory(pid: foregroundPID) { return cwd }
            if let childPID, let cwd = TerminalForegroundProcessInspector.workingDirectory(pid: childPID) { return cwd }
            return nil
        }

        private func observedSurfaceSize() -> (columns: Int, rows: Int)? {
            if let size = rendererHostStorage.surfaceCellSize() {
                lastKnownSurfaceSize = size
                return size
            }
            return lastKnownSurfaceSize
        }

        private func postAttachmentStateDidChange() {
            // Attach/detach/ownership-transfer/stale-expiry all funnel through here, so this is the single
            // point that invalidates the attachment-snapshot cache for every attachment-row mutation except
            // the heartbeat-lease touch (`touchClientLease`) and the client upsert (invalidated inline).
            invalidateAttachmentSnapshotCache()
            TerminalSessionNotification.post(.spacesTerminalAttachmentStateDidChange, sessionID: launchConfiguration.sessionID)
            broadcastCurrentState(reason: "attachment_state")
        }

        private func postSessionMetadataDidChange() {
            TerminalSessionNotification.post(.spacesTerminalSessionMetadataDidChange, sessionID: launchConfiguration.sessionID)
            broadcastCurrentState(reason: "session_metadata")
        }

        private func postRuntimeStateDidChange() {
            TerminalSessionNotification.post(.spacesTerminalRuntimeStateDidChange, sessionID: launchConfiguration.sessionID)
            TerminalOverviewSignal.post()
            broadcastCurrentState(reason: "runtime_state")
        }

        private func postOutputDidChange(data: Data, outputEndByteOffset: Int?, interactiveResync: Bool = false, shouldBroadcastState: Bool = true) {
            TerminalSessionNotification.post(.spacesTerminalOutputDidChange, sessionID: launchConfiguration.sessionID)
            inputOutputResyncScheduler.handleOutputDidChange(interactive: interactiveResync)
            guard shouldBroadcastState else { return }
            broadcastCurrentState(reason: "output", outputByteCount: data.count, outputEndByteOffset: outputEndByteOffset)
        }

        private func handleOwnerInputActivity(byteCount: Int) {
            guard let ownerClient = activeOwnerClient() else { return }
            let interactiveInput = byteCount > 0 && byteCount <= Self.interactiveInputMaximumByteCount
            logMobileTakeoverPerformance(
                name: "owner_input_activity", count: byteCount,
                attributes: ["owner_kind": ownerClient.kind.rawValue, "interactive": interactiveInput ? "1" : "0"])
            if interactiveInput { interactiveOutputGate.markActivity(windowNanoseconds: Self.interactiveInputFlushWindowNanoseconds) }
            if ownerClient.kind == .localWindow {
                inputOutputResyncScheduler.noteLocalOwnerInput()
                return
            }
            scheduleInputStateBroadcast()
        }

        private func markLocalOwnerCommandInputOutputResyncPending() {
            guard activeOwnerClient()?.kind == .localWindow else { return }
            inputOutputResyncScheduler.noteLocalOwnerCommand()
        }

        private func scheduleInputStateBroadcast() {
            inputStateBroadcastCoalescer.schedule { [weak self] in
                guard let self else { return }
                self.requestSurfaceRefreshAction()
                GhosttyEmbeddedAppService.shared.tick()
                self.broadcastCurrentState(reason: "input")
            }
        }

        private func scheduleScreenStateChangeBroadcast(revision: UInt64) {
            guard activeOwnerClient() != nil else { return }
            pendingScreenStateChangeBroadcastRevision = max(pendingScreenStateChangeBroadcastRevision ?? revision, revision)
            screenStateChangeBroadcastCoalescer.schedule { [weak self] in
                guard let self else { return }
                let revision = self.pendingScreenStateChangeBroadcastRevision
                self.pendingScreenStateChangeBroadcastRevision = nil
                guard self.screenStateRevisionNeedsExport(revision) else { return }
                self.requestSurfaceRefreshAction()
                GhosttyEmbeddedAppService.shared.tick()
                guard self.screenStateRevisionNeedsExport(revision) else { return }
                self.broadcastCurrentState(reason: TerminalRemoteSessionStateReason.stateChange)
            }
        }

        private func screenStateRevisionNeedsExport(_ revision: UInt64?) -> Bool {
            guard let revision else { return true }
            guard let lastExportedScreenStateRevision else { return true }
            return lastExportedScreenStateRevision < revision
        }

        private func nowISO8601() -> String { TerminalSessionTimestamp.string(from: Date()) }

        private static func clampedInt(_ value: UInt64) -> Int {
            guard value <= UInt64(Int.max) else { return Int.max }
            return Int(value)
        }

        private static func normalizedSessionMetadataValue(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func clientForAttachLease(_ client: TerminalClient, attachedAt: String) -> TerminalClient {
            guard client.kind != .localWindow else { return client }
            return TerminalClient(id: client.id, kind: client.kind, identity: client.identity, connectedAt: attachedAt, disconnectedAt: nil)
        }

        private func activeOwnerClient() -> TerminalClient? {
            guard isRuntimeInteractiveForControl() else { return nil }
            guard let snapshot = currentAttachmentSnapshot(),
                let attachment = snapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })
            else { return nil }
            return snapshot.clients.first(where: { $0.id == attachment.clientID })
        }

        /// The session's attachment snapshot, served from `cachedAttachmentSnapshot` and read from disk only
        /// on a cache miss. See `cachedAttachmentSnapshot` for the single-writer invariant that makes serving
        /// the cache on the hot path sound.
        private func currentAttachmentSnapshot() -> TerminalSessionAttachmentSnapshot? {
            if let cachedAttachmentSnapshot { return cachedAttachmentSnapshot }
            guard let snapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths) else { return nil }
            cachedAttachmentSnapshot = snapshot
            return snapshot
        }

        /// Drops the cached attachment snapshot so the next read reseeds from disk. Called by every in-core
        /// attachment-row write.
        private func invalidateAttachmentSnapshotCache() { cachedAttachmentSnapshot = nil }

        /// Refreshes a client's heartbeat lease and invalidates the attachment-snapshot cache (the lease
        /// timestamp is part of the cached snapshot). No-op when the client id is absent.
        private func touchClientLease(_ clientID: String?) {
            guard let clientID else { return }
            try? TerminalSessionPersistence.touchClient(id: clientID, paths: paths, touchedAt: nowISO8601())
            invalidateAttachmentSnapshotCache()
        }

        private func isRuntimeInteractiveForControl() -> Bool {
            if started { return true }
            let runtimeState = (try? TerminalSessionPersistence.readRuntimeState(paths: paths)) ?? lastPersistedRuntimeState
            guard let runtimeState else { return true }
            return runtimeState.state.isInteractive
        }

        nonisolated static func shouldClearFocusAfterDetachingClient(detachedClientWasOwner: Bool, remainingOwnerClientID: String?) -> Bool {
            detachedClientWasOwner || remainingOwnerClientID == nil
        }

        private func shouldPersistRuntimeState(_ state: TerminalSessionRuntimeState, now: Date) -> Bool {
            if let lastPersistedRuntimeState, runtimeStateSignature(for: lastPersistedRuntimeState) != runtimeStateSignature(for: state) {
                return true
            }
            guard let lastRuntimeStateWriteAt else { return true }
            return now.timeIntervalSince(lastRuntimeStateWriteAt) >= 5
        }

        private func runtimeStateSignature(for state: TerminalSessionRuntimeState) -> String {
            "\(state.sessionID)|\(state.backend.rawValue)|\(state.servicePID)|\(state.childPID.map(String.init) ?? "nil")|\(state.foregroundPID.map(String.init) ?? "nil")|\(state.foregroundExecutablePath ?? "nil")|\(state.foregroundExecutableName ?? "nil")|\(state.foregroundArgv?.joined(separator: "\u{1F}") ?? "nil")|\(state.foregroundDetectedAgentKind?.rawValue ?? "nil")|\(state.foregroundDisplayLabel ?? "nil")|\(state.foregroundDisplayCommand ?? "nil")|\(state.title ?? "nil")|\(state.workingDirectory ?? "nil")|\(state.columns.map(String.init) ?? "nil")|\(state.rows.map(String.init) ?? "nil")|\(state.state.rawValue)|\(state.exitedAt ?? "nil")"
        }

        private static func isProcessAlive(pid: Int32) -> Bool {
            guard pid > 0 else { return false }
            if kill(pid, 0) == 0 { return true }
            return errno == EPERM
        }

        private nonisolated func enqueueIncomingOutput(_ data: Data) {
            let flushSchedule = incomingOutputBuffer.append(data, interactive: interactiveOutputGate.consumeIfActive())
            guard flushSchedule != .none else { return }
            Task { [weak self] in
                if flushSchedule == .delayed { do { try await Task.sleep(for: Self.incomingOutputCoalescingInterval) } catch { return } }
                guard let self else { return }
                // Drain ON the terminal engine actor so drain and file append form one critical
                // section. Every other drain (clearScreenAndScrollback's transcript
                // mutation, the quiesce flush) runs on the engine actor too, so this keeps
                // output.log byte order identical to buffer order. Draining here off the
                // engine actor would let an engine-actor drain+append (e.g. a clear) write
                // first, landing these earlier bytes AFTER the clear in the transcript —
                // a handoff replay would then resurrect the cleared screen.
                await TerminalEngineActor.run {
                    let drainedOutput = self.incomingOutputBuffer.drain()
                    guard !drainedOutput.data.isEmpty else { return }
                    _ = self.appendOutput(drainedOutput.data, interactiveResync: drainedOutput.isInteractive)
                }
            }
        }

        private func flushPendingIncomingOutputForStateExport() {
            let coalescedData = incomingOutputBuffer.drain()
            guard !coalescedData.data.isEmpty else { return }
            appendOutput(coalescedData.data, interactiveResync: coalescedData.isInteractive, shouldBroadcastState: false)
        }

        func prepareRenderStateExport() { flushPendingIncomingOutputForStateExport() }

        public func currentRemoteStatePayload(reason: String = TerminalRemoteSessionStateReason.stateChange) -> GhosttyRemoteSessionStatePayload? {
            currentRemoteSessionState(reason: reason, outputByteCount: nil, exportMode: .selfContained)
        }

        private func broadcastCurrentState(reason: String, outputByteCount: Int? = nil, outputEndByteOffset: Int? = nil) {
            guard !suppressBroadcastsForHandoff else { return }
            let startedAt = Date()
            let ownerClient = activeOwnerClient()
            let includeScreenState = Self.remoteStateShouldIncludeScreenState(reason: reason, ownerKind: ownerClient?.kind)
            trace(
                "broadcast_state_begin reason=\(reason) include_screen=\(includeScreenState ? 1 : 0) runtime=\(traceSize(observedSurfaceSize())) output_bytes=\(outputByteCount ?? 0)"
            )
            guard stateStreamServer != nil,
                let payload = currentRemoteSessionState(
                    reason: reason, outputByteCount: outputByteCount, outputEndByteOffset: outputEndByteOffset, exportMode: .streamDeltaAllowed)
            else { return }
            broadcastRemoteStatePayload(payload, startedAt: startedAt, ownerClient: ownerClient, outputByteCount: outputByteCount)
        }

        private func broadcastRemoteStatePayload(
            _ payload: GhosttyRemoteSessionStatePayload, startedAt: Date, ownerClient: TerminalClient?, outputByteCount: Int?
        ) {
            let payloadEncodeStartedAt = Date()
            let encodedPayload = try? GhosttyRemoteSessionStateCodec.encodeLine(payload)
            let payloadEncodeMS = TerminalPerformance.elapsedMS(since: payloadEncodeStartedAt)
            stateStreamServer?.broadcast(payload)
            let payloadBytes = encodedPayload?.count ?? 0
            let decodedUpdate = payload.decodedRenderUpdate
            let renderUpdateAttributes = GhosttyRenderFrameMetrics.attributes(
                reason: payload.reason, frame: decodedUpdate?.fullFrame, payloadByteCount: payloadBytes, payloadEncodeMS: payloadEncodeMS,
                outputByteCount: outputByteCount, screenStateRevision: payload.screenStateRevision, frameKind: decodedUpdate?.frameKindMetricValue,
                baseRevision: decodedUpdate?.baseRevision, targetRevision: decodedUpdate?.targetRevision ?? payload.screenStateRevision,
                operationCount: decodedUpdate?.operationCount, changedCellCount: decodedUpdate?.changedCellCount,
                scrollOperationCount: decodedUpdate?.scrollOperationCount, fullFrameFallbackReason: decodedUpdate?.fallbackReason)
            logMobileTakeoverPerformance(
                name: "remote_state_publish", count: payloadBytes,
                attributes: [
                    "reason": payload.reason, "owner_kind": ownerClient?.kind.rawValue ?? "nil", "output_bytes": String(outputByteCount ?? 0),
                    "payload_bytes": String(payloadBytes), "render_update": payload.renderUpdate == nil ? "0" : "1",
                    "render_update_bytes": String(payload.renderUpdate?.count ?? 0),
                ])
            logMobileTakeoverPerformance(
                name: "render_frame_payload_publish", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), count: payloadBytes,
                attributes: renderUpdateAttributes)
            trace(
                "broadcast_state_end reason=\(payload.reason) render_update=\(payload.renderUpdate == nil ? 0 : 1) runtime=\(traceSize(columns: payload.runtimeState?.columns, rows: payload.runtimeState?.rows)) owner_epoch=\(ownerEpoch)"
            )
            TerminalPerformance.logMetric(
                "terminal_remote_state_publish", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
                detail:
                    "reason=\(payload.reason) render_update=\(payload.renderUpdate == nil ? 0 : 1) bytes=\(outputByteCount ?? 0) payload_bytes=\(payloadBytes) render_update_bytes=\(payload.renderUpdate?.count ?? 0)"
            )
            TerminalPerformance.logMetric(
                "terminal_render_frame_payload_publish", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
                detail: GhosttyRenderFrameMetrics.detailString(renderUpdateAttributes))
        }

        private func currentRemoteSessionState(
            reason: String, outputByteCount: Int?, outputEndByteOffset: Int? = nil, exportMode: RenderStateExportMode = .selfContained,
            markNextBroadcastFull: Bool = false, markNextBroadcastFullWhenMissingRenderUpdate: Bool = false
        ) -> GhosttyRemoteSessionStatePayload? {
            // Serve runtime state from memory: this core is the sole writer of a live session's runtime
            // state and keeps `lastPersistedRuntimeState` in lockstep with every disk write (see the two
            // `writeRuntimeState` sites), so the in-memory copy is authoritative. Falling back to disk only
            // covers the brief pre-first-persist window. This removes a per-output-chunk SQLite open that
            // otherwise saturated the serial terminal-engine executor and starved input.
            let runtimeState = lastPersistedRuntimeState ?? (try? TerminalSessionPersistence.readRuntimeState(paths: paths))
            let attachmentSnapshot = currentAttachmentSnapshot()
            let ownerClient = activeOwnerClient()
            let includeScreenState = Self.remoteStateShouldIncludeScreenState(reason: reason, ownerKind: ownerClient?.kind)
            let bootstrapOutputByteCount = outputByteCount
            let bootstrapOutputEndByteOffset = outputEndByteOffset
            if includeScreenState {
                let snapshotExportStartedAt = Date()
                trace(
                    "snapshot_export_begin reason=\(reason) runtime=\(traceSize(columns: runtimeState?.columns, rows: runtimeState?.rows)) owner=\(attachmentSnapshot?.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID ?? "nil")"
                )
                logMobileTakeoverPerformance(
                    name: "snapshot_export_begin",
                    attributes: [
                        "reason": reason, "owner_kind": ownerClient?.kind.rawValue ?? "nil", "runtime_columns": String(runtimeState?.columns ?? 0),
                        "runtime_rows": String(runtimeState?.rows ?? 0),
                    ])
                let resolvedScreenState = resolveRemoteScreenState(runtimeState: runtimeState, reason: reason, ownerKind: ownerClient?.kind)
                let snapshot = resolvedScreenState.snapshot
                let frame = snapshot.map { GhosttyRenderFrame(sessionRevision: renderFrameRevision(for: $0), ownerEpoch: ownerEpoch, snapshot: $0) }
                let renderUpdateEncodeStartedAt = Date()
                let renderUpdateValue = frame.map {
                    makeRenderUpdate(for: $0, reason: reason, nativeScrollRects: resolvedScreenState.scrollRects, exportMode: exportMode)
                }
                let renderUpdate = renderUpdateValue.flatMap { try? GhosttyRenderUpdateBinaryCodec.encode($0) }
                if renderUpdate != nil, markNextBroadcastFull { forceNextBroadcastFullRenderUpdate = true }
                if renderUpdate == nil, markNextBroadcastFullWhenMissingRenderUpdate { forceNextBroadcastFullRenderUpdate = true }
                let renderUpdateEncodeMS = TerminalPerformance.elapsedMS(since: renderUpdateEncodeStartedAt)
                if renderUpdate != nil, let lastScreenStateRevision, exportMode == .streamDeltaAllowed {
                    lastExportedScreenStateRevision = lastScreenStateRevision
                }
                trace(
                    "render_frame_export_end reason=\(reason) render_update=\(renderUpdate == nil ? 0 : 1) frame_size=\(traceSize(columns: snapshot?.columns, rows: snapshot?.rows)) source=\(resolvedScreenState.source) owner_epoch=\(ownerEpoch)"
                )
                var renderUpdateAttributes = GhosttyRenderFrameMetrics.attributes(
                    reason: reason, frame: frame, outputByteCount: outputByteCount, screenStateRevision: lastScreenStateRevision,
                    frameKind: renderUpdateValue?.frameKindMetricValue, baseRevision: renderUpdateValue?.baseRevision,
                    targetRevision: renderUpdateValue?.targetRevision ?? lastScreenStateRevision, operationCount: renderUpdateValue?.operationCount,
                    changedCellCount: renderUpdateValue?.changedCellCount, scrollOperationCount: renderUpdateValue?.scrollOperationCount,
                    fullFrameFallbackReason: renderUpdateValue?.fallbackReason)
                renderUpdateAttributes["source"] = resolvedScreenState.source
                renderUpdateAttributes["owner_kind"] = ownerClient?.kind.rawValue ?? "nil"
                renderUpdateAttributes["render_update_bytes"] = String(renderUpdate?.count ?? 0)
                renderUpdateAttributes["render_update_encode_ms"] = String(renderUpdateEncodeMS)
                logMobileTakeoverPerformance(
                    name: "render_frame_export_end", elapsedMS: TerminalPerformance.elapsedMS(since: snapshotExportStartedAt),
                    count: renderUpdate?.count, attributes: renderUpdateAttributes)
                TerminalPerformance.logMetric(
                    "terminal_render_frame_export", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: snapshotExportStartedAt), success: renderUpdate != nil,
                    detail: GhosttyRenderFrameMetrics.detailString(renderUpdateAttributes))
                return GhosttyRemoteSessionStatePayload(
                    sessionID: launchConfiguration.sessionID, reason: reason, emittedAt: GhosttyRemoteSessionStateTimestamp.string(from: Date()),
                    sessionStateRevision: lastSessionStateRevision, sessionStateFlags: lastSessionStateFlags?.rawValue,
                    screenStateRevision: lastScreenStateRevision, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
                    title: effectiveTitle, workingDirectory: effectiveWorkingDirectory, outputByteCount: bootstrapOutputByteCount,
                    outputEndByteOffset: bootstrapOutputEndByteOffset, renderUpdate: renderUpdate)
            }
            if markNextBroadcastFullWhenMissingRenderUpdate { forceNextBroadcastFullRenderUpdate = true }
            return GhosttyRemoteSessionStatePayload(
                sessionID: launchConfiguration.sessionID, reason: reason, emittedAt: GhosttyRemoteSessionStateTimestamp.string(from: Date()),
                sessionStateRevision: lastSessionStateRevision, sessionStateFlags: lastSessionStateFlags?.rawValue,
                screenStateRevision: lastScreenStateRevision, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
                title: effectiveTitle, workingDirectory: effectiveWorkingDirectory, outputByteCount: bootstrapOutputByteCount,
                outputEndByteOffset: bootstrapOutputEndByteOffset)
        }

        private func makeRenderUpdate(
            for frame: GhosttyRenderFrame, reason: String, nativeScrollRects: [GhosttyRenderScrollRectOperation] = [],
            exportMode: RenderStateExportMode = .selfContained
        ) -> GhosttyRenderUpdate {
            let hasPendingSubscriberBaselineReset = exportMode == .streamDeltaAllowed && forceNextBroadcastFullRenderUpdate
            let forceFullForSubscriberBaseline = hasPendingSubscriberBaselineReset && reason != TerminalRemoteSessionStateReason.scroll
            let forceFullForSelfContainedExport = exportMode == .selfContained
            let forceFullForExplicitResync =
                reason == TerminalRemoteSessionStateReason.initial || reason == TerminalRemoteSessionStateReason.inputOutput
                || reason == TerminalRemoteSessionStateReason.resize || reason == TerminalRemoteSessionStateReason.terminated
            let forceFull =
                forceFullForExplicitResync || forceFullForSelfContainedExport || lastRenderUpdateBaseline?.sessionRevision == frame.sessionRevision
                || forceFullForSubscriberBaseline
            let forceFullReason =
                if reason == TerminalRemoteSessionStateReason.initial {
                    "initial_baseline"
                } else if reason == TerminalRemoteSessionStateReason.inputOutput || reason == TerminalRemoteSessionStateReason.terminated {
                    "explicit_resync"
                } else if reason == TerminalRemoteSessionStateReason.resize { "resize_self_contained" } else if forceFullForSubscriberBaseline {
                    "subscriber_baseline_reset"
                } else if forceFullForSelfContainedExport { "self_contained_state_export" } else { "baseline_already_current" }
            let update = GhosttyRenderUpdateFactory.makeUpdate(
                target: frame, baseline: lastRenderUpdateBaseline, forceFull: forceFull, forceFullReason: forceFullReason,
                nativeScrollRects: nativeScrollRects)
            let shouldUpdateStreamBaseline = exportMode == .streamDeltaAllowed
            switch update.kind {
            case .full:
                if shouldUpdateStreamBaseline, let fullFrame = update.fullFrame {
                    lastRenderUpdateBaseline = GhosttyRenderUpdateBaseline(frame: fullFrame)
                }
            case .delta:
                if let appliedBaseline = try? GhosttyRenderUpdateApplier.apply(update, to: lastRenderUpdateBaseline) {
                    lastRenderUpdateBaseline = appliedBaseline
                } else {
                    let fullUpdate = GhosttyRenderUpdate.full(frame, fallbackReason: "local_delta_apply_failed")
                    if shouldUpdateStreamBaseline { lastRenderUpdateBaseline = GhosttyRenderUpdateBaseline(frame: frame) }
                    return fullUpdate
                }
            case .resyncRequired: if shouldUpdateStreamBaseline { lastRenderUpdateBaseline = nil }
            }
            if hasPendingSubscriberBaselineReset { forceNextBroadcastFullRenderUpdate = false }
            return update
        }

        private func renderFrameRevision(for snapshot: GhosttyTerminalSnapshot) -> UInt64 {
            if let lastScreenStateRevision, lastScreenStateRevision > renderUpdateRevision {
                renderUpdateRevision = lastScreenStateRevision
            } else if renderUpdateRevision == 0, let lastSessionStateRevision {
                renderUpdateRevision = lastSessionStateRevision
            } else if renderUpdateRevision == 0 {
                renderUpdateRevision = 1
            }

            if let baselineRevision = lastRenderUpdateBaseline?.sessionRevision, baselineRevision > renderUpdateRevision {
                renderUpdateRevision = baselineRevision
            }
            if let lastRenderUpdateBaseline, lastRenderUpdateBaseline.sessionRevision == Optional(renderUpdateRevision),
                lastRenderUpdateBaseline.snapshot != snapshot
            {
                if renderUpdateRevision < UInt64.max { renderUpdateRevision += 1 }
            }
            return renderUpdateRevision
        }

        private func resolveRemoteScreenState(runtimeState: TerminalSessionRuntimeState?, reason: String, ownerKind: TerminalClientKind?) -> (
            snapshot: GhosttyTerminalSnapshot?, snapshotText: String?, scrollRects: [GhosttyRenderScrollRectOperation], source: String
        ) {
            let liveSessionScreenState = captureLiveSessionScreenState()
            let sessionSnapshot = liveSessionScreenState.snapshot
            let sessionSnapshotText = liveSessionScreenState.snapshotText
            if Self.remoteScreenStateHasVisibleContent(snapshot: sessionSnapshot, snapshotText: sessionSnapshotText) {
                return (
                    snapshot: sessionSnapshot, snapshotText: sessionSnapshotText, scrollRects: liveSessionScreenState.scrollRects, source: "session"
                )
            }

            let isLiveRuntime = runtimeState?.state == .running || runtimeState?.state == .starting
            return (snapshot: nil, snapshotText: nil, scrollRects: [], source: isLiveRuntime ? "session_empty" : "session_unavailable")
        }

        private func captureLiveSessionScreenState() -> (
            snapshot: GhosttyTerminalSnapshot?, snapshotText: String?, scrollRects: [GhosttyRenderScrollRectOperation]
        ) {
            flushPendingIncomingOutputForStateExport()
            rendererHostStorage.prepareRenderStateExport()
            let capturedRenderState = rendererHostStorage.sessionRenderStateSnapshot()
            let sessionSnapshot = capturedRenderState?.snapshot
            let sessionSnapshotText = sessionSnapshot == nil ? rendererHostStorage.sessionSnapshotText() : nil
            return (snapshot: sessionSnapshot, snapshotText: sessionSnapshotText, scrollRects: capturedRenderState?.scrollRects ?? [])
        }

        static func remoteStateShouldIncludeScreenState(reason: String, ownerKind: TerminalClientKind? = nil) -> Bool {
            TerminalRemoteSessionStatePolicy.shouldIncludeScreenState(reason: reason, ownerKind: ownerKind)
        }

        static func remoteScreenStateHasVisibleContent(snapshot: GhosttyTerminalSnapshot?, snapshotText: String?) -> Bool {
            TerminalRemoteSessionStatePolicy.hasVisibleScreenContent(snapshot: snapshot, snapshotText: snapshotText)
        }

        var debugCurrentTitle: String? { currentTitle }
        var debugCurrentWorkingDirectory: String? { currentWorkingDirectory }
        func debugHandleIncomingOutput(_ data: Data) { appendOutput(data, interactiveResync: interactiveOutputGate.consumeIfActive()) }
        func debugBufferIncomingOutputForStateExport(_ data: Data) { _ = incomingOutputBuffer.append(data, interactive: false) }
        func debugStartStateStreamServerForTesting() throws { try startStateStreamServer() }
        func debugStopStateStreamServerForTesting() {
            stateStreamServer?.stop()
            stateStreamServer = nil
            GhosttyRemoteSessionStateStreamServer.removeSocketFileIfPresent(at: paths.subscriptionSocketPath)
        }
        func debugBroadcastCurrentStateForTesting(reason: String) { broadcastCurrentState(reason: reason) }
        func debugHandleOwnerInputActivity(byteCount: Int = 1) { handleOwnerInputActivity(byteCount: byteCount) }
        func debugMarkLocalOwnerCommandInputOutputResyncPending() { markLocalOwnerCommandInputOutputResyncPending() }
        func debugCurrentRemoteSessionState(reason: String) -> GhosttyRemoteSessionStatePayload? {
            currentRemoteSessionState(reason: reason, outputByteCount: nil, exportMode: .selfContained)
        }
        func debugPersistRuntimeState(force: Bool = true) { refreshRuntimeState(force: force) }
        func debugSetLastKnownChildPID(_ pid: Int32?) { lastKnownChildPID = pid }
        func debugSetForegroundPIDForTesting(_ pid: Int32?) { foregroundPIDOverrideForTesting = pid }
        func debugSetForegroundProcessResolverForTesting(_ resolver: @escaping (Int32) -> TerminalForegroundProcessSnapshot?) {
            foregroundProcessResolver = resolver
        }
        func debugSetLastKnownSurfaceSize(columns: Int, rows: Int) { lastKnownSurfaceSize = (columns, rows) }
        func debugHandleSessionClosed() { handleSessionClosed() }
        func debugMarkStartedForTesting() { started = true }

        private func trace(_ message: @autoclosure () -> String) { ghosttyEmbeddedSessionTrace(launchConfiguration.sessionID, message()) }

        private func traceSize(_ size: (columns: Int, rows: Int)?) -> String {
            guard let size else { return "nil" }
            return "\(size.columns)x\(size.rows)"
        }

        private func traceSize(columns: Int?, rows: Int?) -> String {
            guard let columns, let rows else { return "nil" }
            return "\(columns)x\(rows)"
        }

        private func logMobileTakeoverPerformance(name: String, elapsedMS: Int? = nil, count: Int? = nil, attributes: [String: String] = [:]) {
            SpacesDeviceTerminalPerformanceLogger.emit(
                .init(
                    sessionID: launchConfiguration.sessionID, source: "mac-host", name: name, elapsedMS: elapsedMS, count: count,
                    attributes: attributes))
        }

    }

    @TerminalEngineActor public final class GhosttyEmbeddedSessionHost {
        public let core: GhosttyEmbeddedSessionCore

        public var launchConfiguration: TerminalSessionLaunchConfiguration { core.launchConfiguration }
        public var paths: TerminalSessionPaths { core.paths }
        public var rendererHost: GhosttyHeadlessRendererHost { core.rendererHost }

        init(
            launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
            requestSurfaceRefreshAction: (@TerminalEngineActor () -> Void)? = nil
        ) {
            core = GhosttyEmbeddedSessionCore(
                launchConfiguration: launchConfiguration, paths: paths, requestSurfaceRefreshAction: requestSurfaceRefreshAction)
        }

        init(core: GhosttyEmbeddedSessionCore) { self.core = core }

        public func startIfNeeded() throws { try core.startIfNeeded() }

        public func attach(client: TerminalClient, mode: TerminalAttachmentMode, into container: NSView?) throws {
            let startedAt = Date()
            do {
                try core.startIfNeeded()
                guard core.isStarted else { return }
                try core.rendererHost.attach(client: client, mode: mode, into: container)
                try core.attachClient(client, mode: mode)
                // Window focus is an app-side (main-actor) concern handled by RemoteGhosttySessionHost; the
                // headless daemon renderer has no window to key, so an owner attach only refreshes here.
                if mode == .owner, container != nil { core.rendererHost.requestSurfaceRefresh() }
                TerminalPerformance.logMetric(
                    "terminal_window_attach", target: "session=\(launchConfiguration.sessionID) client=\(client.id)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "mode=\(mode.rawValue)")
            } catch {
                TerminalPerformance.logMetric(
                    "terminal_window_attach", target: "session=\(launchConfiguration.sessionID) client=\(client.id)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "mode=\(mode.rawValue)")
                throw error
            }
        }

        public func detach(clientID: String) throws { try core.detach(clientID: clientID) }

        public func releaseRendererSurface() { core.rendererHost.releaseRendererSurface() }

        public func setFocused(_ focused: Bool, for clientID: String) { core.rendererHost.setFocused(focused, for: clientID) }

        public func isOwner(clientID: String) -> Bool { core.isOwner(clientID: clientID) }

        public func activeOwnerClientID() -> String? { core.activeOwnerClientID() }

        public func hasRenderableSurface() -> Bool { core.rendererHost.hasRenderableSurface() }

        public func requestSurfaceRefresh() { core.rendererHost.requestSurfaceRefresh() }

        public func prepareRenderStateExport() { core.rendererHost.prepareRenderStateExport() }

        public func snapshot() -> GhosttyTerminalSnapshot? { return core.rendererHost.snapshot() }

        public func snapshotText() -> String? { return core.rendererHost.snapshotText() }

        public func sessionSnapshot() -> GhosttyTerminalSnapshot? { return core.rendererHost.sessionSnapshot() }

        public func sessionSnapshotText() -> String? { return core.rendererHost.sessionSnapshotText() }

        public func copySelectionToPasteboard() -> Bool { core.rendererHost.copySelectionToPasteboard() }

        public func pasteClipboardContents() -> Bool { core.rendererHost.pasteClipboardContents() }

        @discardableResult public func sendTextAsPaste(_ text: String) -> Bool { core.rendererHost.sendTextAsPaste(text) }

        @discardableResult public func performBindingAction(_ action: String) -> Bool { core.rendererHost.performBindingAction(action) }

        @discardableResult public func sendScroll(
            horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?
        ) -> Bool {
            core.rendererHost.sendScroll(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition)
        }

        @discardableResult public func clearScreenAndScrollback() -> Bool { core.rendererHost.clearScreenAndScrollback() }

        public var debugSearchState: GhosttyTerminalSearchDebugState { core.rendererHost.debugSearchState }

        public var debugSurfaceRefreshRequestCount: Int { core.rendererHost.debugSurfaceRefreshRequestCount }
        public func debugVisibleSurfaceText() -> String? { return core.rendererHost.debugVisibleSurfaceText() }

        public func terminate() { core.terminate() }

        public func childPID() -> Int32? { core.childPID() }

        public var effectiveTitle: String { core.effectiveTitle }

        public var effectiveWorkingDirectory: String { core.effectiveWorkingDirectory }

        func handleControlRequest(_ request: TerminalControlRequest) -> TerminalControlResponse { core.handleControlRequest(request) }
        func applyActionEvent(_ event: GhosttyActionEvent) { core.applyActionEvent(event) }
        func applySessionStateChange(_ change: GhosttyEmbeddedSessionStateChange) { core.applySessionStateChange(change) }
        @discardableResult func expireStaleRemoteClientsIfNeeded(now: Date = Date()) -> [String] { core.expireStaleRemoteClientsIfNeeded(now: now) }

        nonisolated static func shouldClearFocusAfterDetachingClient(detachedClientWasOwner: Bool, remainingOwnerClientID: String?) -> Bool {
            GhosttyEmbeddedSessionCore.shouldClearFocusAfterDetachingClient(
                detachedClientWasOwner: detachedClientWasOwner, remainingOwnerClientID: remainingOwnerClientID)
        }

        var debugCurrentTitle: String? { core.debugCurrentTitle }
        var debugCurrentWorkingDirectory: String? { core.debugCurrentWorkingDirectory }
        func debugHandleIncomingOutput(_ data: Data) { core.debugHandleIncomingOutput(data) }
        func debugBufferIncomingOutputForStateExport(_ data: Data) { core.debugBufferIncomingOutputForStateExport(data) }
        func debugStartStateStreamServerForTesting() throws { try core.debugStartStateStreamServerForTesting() }
        func debugStopStateStreamServerForTesting() { core.debugStopStateStreamServerForTesting() }
        func debugBroadcastCurrentStateForTesting(reason: String) { core.debugBroadcastCurrentStateForTesting(reason: reason) }
        func debugHandleOwnerInputActivity(byteCount: Int = 1) { core.debugHandleOwnerInputActivity(byteCount: byteCount) }
        func debugMarkLocalOwnerCommandInputOutputResyncPending() { core.debugMarkLocalOwnerCommandInputOutputResyncPending() }
        func debugCurrentRemoteSessionState(reason: String) -> GhosttyRemoteSessionStatePayload? {
            core.debugCurrentRemoteSessionState(reason: reason)
        }
        func debugPersistRuntimeState(force: Bool = true) { core.debugPersistRuntimeState(force: force) }
        func debugSetLastKnownChildPID(_ pid: Int32?) { core.debugSetLastKnownChildPID(pid) }
        func debugSetForegroundPIDForTesting(_ pid: Int32?) { core.debugSetForegroundPIDForTesting(pid) }
        func debugSetForegroundProcessResolverForTesting(_ resolver: @escaping (Int32) -> TerminalForegroundProcessSnapshot?) {
            core.debugSetForegroundProcessResolverForTesting(resolver)
        }
        func debugHandleSessionClosed() { core.debugHandleSessionClosed() }
        func debugMarkStartedForTesting() { core.debugMarkStartedForTesting() }
    }

#endif
