#if canImport(AppKit) && canImport(GhosttyKit)
    import AppKit
    import Foundation
    import GhosttyKit
    import spacesterminalcore

    @MainActor private final class GhosttyHeadlessSessionHostView: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }

    private final class GhosttyHostManagedOutputPipe: @unchecked Sendable {
        private let lock = NSLock()
        private var session: ghostty_session_t?

        func setSession(_ session: ghostty_session_t?) {
            lock.lock()
            self.session = session
            lock.unlock()
        }

        func process(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            if let session {
                data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                    ghostty_session_process_output(session, baseAddress, UInt(data.count))
                }
                ghostty_session_refresh(session)
            }
            lock.unlock()
        }
    }

    /// Counts Ghostty data callbacks that have entered Spaces persistence. Handoff
    /// first stops new callbacks at the Ghostty session, then awaits this fence before
    /// the core drains its coalescing buffer and closes output.log.
    final class GhosttyEmbeddedHandoffOutputDeliveryFence: @unchecked Sendable {
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

    @TerminalEngineActor final class GhosttyEmbeddedTerminalSessionDriver {
        private let launchConfiguration: TerminalSessionLaunchConfiguration

        private var session: ghostty_session_t?
        private var hostPTY: HostManagedPTYTerminalSessionDriver?
        /// The headless AppKit host view. It is an `NSView` subclass (implicitly `@MainActor`) created on
        /// the main thread via a synchronous hop and only ever handed to GhosttyKit as an opaque pointer;
        /// nothing on the engine actor calls `NSView` methods on it afterward, so it is stored
        /// `nonisolated(unsafe)` and merely retained.
        private nonisolated(unsafe) var headlessHostView: GhosttyHeadlessSessionHostView?
        private var surfaceUserData: GhosttyEmbeddedSurfaceUserData?
        private let outputPipe = GhosttyHostManagedOutputPipe()
        private let handoffOutputDeliveryFence = GhosttyEmbeddedHandoffOutputDeliveryFence()
        /// Serial queue that runs the blocking `output.log` replay off the main actor
        /// during a handoff resume (see `replayOutputLogOffMainActor`).
        private let handoffReplayQueue = DispatchQueue(label: "spaces.terminal.session.handoff-replay")
        private nonisolated(unsafe) var outputHandler: (@Sendable (Data) -> Void)?
        private var didHandleSurfaceClose = false
        /// Sendable liveness mirror of `session`/`hostPTY` that the nonisolated `deinit` may read (the
        /// GhosttyKit `session` pointer is non-Sendable, so a nonisolated deinit cannot inspect it, and
        /// `isolated deinit` requires macOS 15.4 while this targets macOS 14). Set true once a session is
        /// configured, cleared by `terminate()`/rollback.
        private var hasLiveResources = false
        private var lastKnownSurfaceSize: (columns: Int, rows: Int)?
        private var lastDeliveredSessionStateRevision: UInt64 = 0
        private var sessionStateDeliveryScheduled = false
        private var debugRefreshRequestCountValue = 0
        private var debugLastScrollModsValue: Int32 = 0
        private var surfaceScaleFactor = 1.0

        var onActionEvent: (@TerminalEngineActor (GhosttyActionEvent) -> Void)?
        var onSurfaceClosed: (@TerminalEngineActor () -> Void)?
        var onSurfaceCellSizeChanged: (@TerminalEngineActor (Int, Int) -> Void)?
        var onSessionStateChanged: (@TerminalEngineActor (GhosttyEmbeddedSessionStateChange) -> Void)?

        init(launchConfiguration: TerminalSessionLaunchConfiguration) { self.launchConfiguration = launchConfiguration }

        /// Auto-terminates a driver released while still live (the safety net the old
        /// `MainActor.assumeIsolated` deinit provided). macOS 14 has no `isolated deinit` (macOS 15.4+),
        /// and a nonisolated `deinit` may not touch the non-Sendable GhosttyKit `session` directly — but
        /// it CAN read the Sendable liveness flag and bridge SYNCHRONOUSLY onto the terminal engine actor
        /// to run `terminate()` there (which then touches the session in-isolation). `terminate()` performs
        /// no engine→main hop, so this synchronous engine bridge is deadlock-free even from an arbitrary
        /// deinit thread. This matters because a live session's C data/state callbacks capture
        /// `Unmanaged.passUnretained(self)`; freeing the session (which `terminate()` does) before `self`
        /// is gone is what prevents a use-after-free.
        deinit {
            let leakedLiveSession = hasLiveResources
            if leakedLiveSession { TerminalEngineActor.runSynchronously { self.terminate() } }
        }

        var surface: ghostty_surface_t? {
            guard let session else { return nil }
            return ghostty_session_surface(session)
        }

        var debugRefreshRequestCount: Int { debugRefreshRequestCountValue }
        var debugLastScrollMods: Int32 { debugLastScrollModsValue }

        func setOutputHandler(_ handler: (@Sendable (Data) -> Void)?) { outputHandler = handler }

        func startIfNeeded() throws {
            guard session == nil, hostPTY == nil else { return }

            let (createdSession, hostPTY) = try configureNewSession()

            do { try hostPTY.startIfNeeded() } catch {
                rollbackSessionConfiguration(createdSession)
                throw error
            }

            finalizeSessionAdoption(createdSession, hostPTY: hostPTY, initialSize: lastKnownSurfaceSize ?? hostPTY.surfaceCellSize())
        }

        /// Resume side of the exec-in-place handoff: rebuild the headless GhosttyKit
        /// session for a PTY this process already owns (its master fd survived `execv`
        /// with `FD_CLOEXEC` cleared and the child stayed our child), replay the
        /// persisted `output.log` to reconstruct the screen, and only then adopt the
        /// PTY. Ordering is the reflow-correctness invariant: the grid MUST be resized
        /// to the persisted `(columns, rows)` before any byte is replayed (replaying at
        /// the wrong width reflows line wrapping incorrectly), and the PTY read loop
        /// (which `adopt` starts) must not deliver a live byte into the session until
        /// the replay has finished. Hence: create session → resize → replay → adopt.
        ///
        /// This is `async` because `ghostty_session_process_output` is a BLOCKING call
        /// that waits for the session's IO to drain, and that IO is pumped by
        /// `ghostty_app_tick` on the main actor. Running the replay on the main actor
        /// would deadlock (the main actor would be blocked inside `process_output`,
        /// unable to tick). Instead the replay runs on a background queue — exactly as
        /// the live PTY read loop already does — while the awaiting main actor stays
        /// free to service the app's wakeup ticks.
        func adoptFromHandoff(masterFD: Int32, childPID: Int32, columns: Int, rows: Int, outputLogPath: String) async throws {
            guard session == nil, hostPTY == nil else { return }

            let (createdSession, hostPTY) = try configureNewSession()

            // The session is created parked/occluded like a fresh one; the read loop is
            // not running yet (adopt below starts it), so nothing can race the replay.
            ghostty_session_set_focus(createdSession, false)
            ghostty_session_set_occlusion(createdSession, true)

            // 1. Converge the grid to the persisted size BEFORE replay so wrapping/reflow
            //    of the replayed scrollback matches what the pre-handoff daemon rendered.
            _ = resizeCellGrid(columns: columns, rows: rows)

            // 2. Replay the durable output.log through the exact path a live PTY byte
            //    takes (`outputPipe.process` → `ghostty_session_process_output`).
            //
            //    Suppress the surface data-callback sink for the duration of the replay:
            //    `process_output` re-emits every processed byte to the data callback
            //    (that callback is the host's persistence/broadcast tee, which is how
            //    output.log gets written in the first place), so leaving it wired would
            //    append the entire transcript to output.log a second time. The screen is
            //    still fully reconstructed — the callback only tees, it does not parse.
            let restoreOutputHandler = outputHandler
            outputHandler = nil
            await replayOutputLogOffMainActor(at: outputLogPath, startingAt: 0)
            outputHandler = restoreOutputHandler
            ghostty_session_refresh(createdSession)
            GhosttyEmbeddedAppService.shared.tick()

            finalizeSessionAdoption(createdSession, hostPTY: hostPTY, initialSize: (columns: columns, rows: rows), startReadLoop: false)

            // 3. Adopt the PTY LAST: `adopt` starts the read loop, so from here on live
            //    bytes flow into the already-reconstructed session.
            hostPTY.adopt(masterFD: masterFD, childPID: childPID)
        }

        /// Shared construction body for `startIfNeeded` and `adoptFromHandoff`: creates
        /// the headless GhosttyKit session, wires the surface data/state callbacks and
        /// the host-managed PTY receive callbacks identically, and installs the host
        /// PTY output/closed handlers. It does NOT start or adopt the PTY — the caller
        /// decides whether to fork a fresh child (`hostPTY.startIfNeeded()`) or adopt an
        /// inherited one (`hostPTY.adopt(...)`).
        private func configureNewSession() throws -> (session: ghostty_session_t, hostPTY: HostManagedPTYTerminalSessionDriver) {
            try GhosttyEmbeddedAppService.shared.startIfNeeded()
            guard let app = GhosttyEmbeddedAppService.shared.app else { throw GhosttyEmbeddedAppServiceError.configuration("ghostty app missing") }

            let hostPTY = HostManagedPTYTerminalSessionDriver(launchConfiguration: launchConfiguration)
            let hostView = headlessSurfaceHostView()
            // NSScreen is main-only; resolve the backing scale via the legal engine→main hop.
            let scaleFactor = Self.mainActorSync { Double(NSScreen.main?.backingScaleFactor ?? 2.0) }
            surfaceScaleFactor = scaleFactor

            var sessionConfig = ghostty_session_config_new()
            sessionConfig.surface.platform_tag = GHOSTTY_PLATFORM_MACOS
            sessionConfig.surface.platform = ghostty_platform_u(
                macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(hostView).toOpaque()))
            sessionConfig.surface.scale_factor = scaleFactor
            sessionConfig.surface.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
            sessionConfig.surface.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
            sessionConfig.surface.receive_userdata = Unmanaged.passUnretained(hostPTY).toOpaque()
            sessionConfig.surface.receive_buffer = Self.hostManagedReceiveBufferCallback
            sessionConfig.surface.receive_resize = Self.hostManagedReceiveResizeCallback

            let surfaceUserData = GhosttyEmbeddedSurfaceUserData(
                closeHandler: { [weak self] in self?.handleSurfaceClosed() }, surfaceProvider: { [weak self] in self?.surface })
            self.surfaceUserData = surfaceUserData
            sessionConfig.surface.userdata = Unmanaged.passUnretained(surfaceUserData).toOpaque()

            sessionConfig.parked_host.platform_tag = GHOSTTY_PLATFORM_MACOS
            sessionConfig.parked_host.platform = ghostty_platform_u(
                macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(hostView).toOpaque()))
            sessionConfig.parked_host.scale_factor = scaleFactor

            let workingDirectory = launchConfiguration.workingDirectory
            let createdSession = workingDirectory.withCString { cwd in
                sessionConfig.surface.working_directory = cwd
                return ghostty_session_new_headless(app, &sessionConfig)
            }
            guard let createdSession else { throw GhosttyEmbeddedAppServiceError.configuration("ghostty_session_new_headless failed") }

            session = createdSession
            self.hostPTY = hostPTY
            hasLiveResources = true
            outputPipe.setSession(createdSession)
            didHandleSurfaceClose = false
            ghostty_session_set_data_callback(createdSession, Self.surfaceDataCallback, Unmanaged.passUnretained(self).toOpaque())
            ghostty_session_set_state_callback(createdSession, Self.sessionStateCallback, Unmanaged.passUnretained(self).toOpaque())
            if let surface = surface {
                GhosttyEmbeddedAppService.shared.registerActionHandler(for: surface) { [weak self] event in self?.onActionEvent?(event) }
            }
            hostPTY.setOutputHandler { [weak self, outputPipe] data in
                outputPipe.process(data)
                Task { @TerminalEngineActor [weak self] in
                    GhosttyEmbeddedAppService.shared.tick()
                    self?.deliverSessionStateChange()
                }
            }
            hostPTY.setSessionClosedHandler { [weak self] in self?.handleHostPTYClosed() }
            return (createdSession, hostPTY)
        }

        /// Undoes `configureNewSession` when the host PTY fails to start: mirror the
        /// teardown the old inline `startIfNeeded` catch performed.
        private func rollbackSessionConfiguration(_ createdSession: ghostty_session_t) {
            hostPTY?.setOutputHandler(nil)
            hostPTY?.setSessionClosedHandler(nil)
            hostPTY = nil
            outputPipe.setSession(nil)
            ghostty_session_set_data_callback(createdSession, nil, nil)
            ghostty_session_set_state_callback(createdSession, nil, nil)
            if let surface = surface { GhosttyEmbeddedAppService.shared.unregisterActionHandler(for: surface) }
            session = nil
            hasLiveResources = false
            surfaceUserData = nil
            ghostty_session_free(createdSession)
        }

        /// Post-construction bring-up shared by fresh starts and handoff resumes. When
        /// `startReadLoop` is false the caller has already converged the grid and driven
        /// the PTY setup (handoff replay path), so this only refreshes and publishes.
        private func finalizeSessionAdoption(
            _ createdSession: ghostty_session_t, hostPTY: HostManagedPTYTerminalSessionDriver, initialSize: (columns: Int, rows: Int),
            startReadLoop: Bool = true
        ) {
            if startReadLoop {
                ghostty_session_set_focus(createdSession, false)
                ghostty_session_set_occlusion(createdSession, true)
                _ = resizeCellGrid(columns: initialSize.columns, rows: initialSize.rows)
            }
            ghostty_session_refresh(createdSession)
            deliverSessionStateChange(forcedFlags: .allKnown)
            notifySurfaceCellSizeIfChanged()
        }

        /// Streams the persisted transcript back into the freshly created session in
        /// bounded chunks so a multi-gigabyte log never materializes as one `Data`. Each
        /// chunk goes through `outputPipe.process` — the same call the live PTY read loop
        /// uses — so the reconstructed screen matches what the original daemon had.
        ///
        /// The `process` call is dispatched to a background queue and awaited, never run
        /// inline on the main actor: `ghostty_session_process_output` blocks until the
        /// session IO drains, and that IO is driven by `ghostty_app_tick` on the main
        /// actor. Awaiting a background dispatch keeps the main actor free to service the
        /// app's wakeup ticks so the blocking process call can complete (mirrors how the
        /// live read loop calls `process` off the main actor while main pumps ticks).
        private func replayOutputLogOffMainActor(at path: String, startingAt offset: UInt64) async {
            guard let handle = FileHandle(forReadingAtPath: path) else { return }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: offset)) != nil else { return }
            let chunkByteCount = 1024 * 1024
            let pipe = outputPipe
            let queue = handoffReplayQueue
            while true {
                let chunk = handle.readData(ofLength: chunkByteCount)
                if chunk.isEmpty { break }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    queue.async {
                        pipe.process(chunk)
                        continuation.resume()
                    }
                }
            }
        }

        // MARK: - Exec-in-place handoff (quiesce side)

        /// The live PTY master fd + child pid to carry across the handoff, or nil when
        /// there is nothing to hand off. Forwarded from the host PTY driver.
        func handoffDescriptorSnapshot() -> (masterFD: Int32, childPID: Int32)? { hostPTY?.handoffDescriptorSnapshot() }

        /// Swap PTY output delivery to an in-memory buffer so the read loop keeps
        /// draining while the daemon quiesces and closes its durable output handle.
        func beginHandoffOutputBuffering() async {
            if let hostPTY { await hostPTY.beginHandoffOutputBuffering() }
            // The PTY barrier above waits for every processOutput call selected before
            // its sink swap. Removing the callback then closes Ghostty's delivery source;
            // the second fence proves callbacks already inside Spaces have returned.
            if let session { ghostty_session_set_data_callback(session, nil, nil) }
            await handoffOutputDeliveryFence.waitUntilDrained()
        }

        /// Flush the buffered PTY bytes to `path` and install a direct-to-file writer
        /// that keeps appending until `execv`.
        func finishHandoffOutputBuffering(appendingTo path: String) throws { try hostPTY?.finishHandoffOutputBuffering(appendingTo: path) }

        func withValidatedHandoffOutputForExec<T>(_ operation: () throws -> T) throws -> T {
            guard let hostPTY else { throw POSIXError(.EIO) }
            return try hostPTY.withValidatedHandoffOutputForExec(operation)
        }

        /// Stop direct transcript appends before the core reads the persisted handoff
        /// range or seeks its normal output handle. New PTY bytes remain buffered.
        func pauseHandoffOutputForFallback() { hostPTY?.pauseHandoffOutputForFallback() }

        /// Replays only the bytes persisted while the renderer was disconnected. The
        /// Ghostty data callback remains disabled, so replay updates the renderer without
        /// appending those bytes to the transcript a second time.
        func replayPersistedHandoffOutput(at path: String, startingAt offset: UInt64) async {
            await replayOutputLogOffMainActor(at: path, startingAt: offset)
            if let session { ghostty_session_refresh(session) }
            GhosttyEmbeddedAppService.shared.tick()
        }

        /// Final failed-`execv` fallback step: restore the data callback and normal PTY
        /// delivery, replaying only bytes that accumulated after the direct writer stopped.
        func endHandoffOutputBuffering() async {
            if let session { ghostty_session_set_data_callback(session, Self.surfaceDataCallback, Unmanaged.passUnretained(self).toOpaque()) }
            guard let hostPTY else { return }
            let queue = handoffReplayQueue
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    hostPTY.endHandoffOutputBuffering()
                    continuation.resume()
                }
            }
            await handoffOutputDeliveryFence.waitUntilDrained()
        }

        func terminate() {
            let currentSession = session
            let currentHostPTY = hostPTY
            if let currentSession {
                let surface = ghostty_session_surface(currentSession)
                GhosttyEmbeddedAppService.shared.unregisterActionHandler(for: surface)
                ghostty_session_set_data_callback(currentSession, nil, nil)
                ghostty_session_set_state_callback(currentSession, nil, nil)
            }
            outputPipe.setSession(nil)
            currentHostPTY?.setOutputHandler(nil)
            currentHostPTY?.setSessionClosedHandler(nil)
            hostPTY = nil
            session = nil
            hasLiveResources = false
            surfaceUserData = nil
            lastDeliveredSessionStateRevision = 0
            sessionStateDeliveryScheduled = false
            currentHostPTY?.terminate()
            if let currentSession { ghostty_session_free(currentSession) }
            lastKnownSurfaceSize = nil
            headlessHostView = nil
        }

        func requestSurfaceRefresh() {
            debugRefreshRequestCountValue += 1
            guard let session else { return }
            ghostty_session_refresh(session)
        }

        func sendRawBytes(_ data: Data) {
            guard let session, !data.isEmpty else { return }
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                ghostty_session_send_input_raw(session, baseAddress, UInt(data.count))
            }
            GhosttyEmbeddedAppService.shared.tick()
            requestSurfaceRefresh()
            GhosttyEmbeddedAppService.shared.tick()
        }

        func sendTextAsPaste(_ text: String) {
            guard let surface = surface, !text.isEmpty else { return }
            let data = Data(text.utf8)
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                ghostty_surface_text(surface, baseAddress, UInt(data.count))
            }
            GhosttyEmbeddedAppService.shared.tick()
            requestSurfaceRefresh()
            GhosttyEmbeddedAppService.shared.tick()
        }

        func foregroundPID() -> Int32? {
            if let pid = hostPTY?.foregroundPID() { return pid }
            guard let session else { return nil }
            let pid = ghostty_session_foreground_pid(session)
            guard pid > 0 else { return nil }
            return Int32(pid)
        }

        func childPID() -> Int32? { hostPTY?.childPID() }

        func surfaceCellSize() -> (columns: Int, rows: Int)? {
            guard let session else { return hostPTY?.surfaceCellSize() ?? lastKnownSurfaceSize }
            let size = ghostty_session_size(session)
            guard size.columns > 0, size.rows > 0 else { return hostPTY?.surfaceCellSize() ?? lastKnownSurfaceSize }
            let resolved = (columns: Int(size.columns), rows: Int(size.rows))
            lastKnownSurfaceSize = resolved
            return resolved
        }

        func setFocused(_ focused: Bool) {
            guard let session else { return }
            ghostty_session_set_focus(session, focused)
        }

        @discardableResult func resizeCellGrid(columns: Int, rows: Int) -> Bool {
            let targetColumns = max(min(columns, Int(UInt16.max)), 1)
            let targetRows = max(min(rows, Int(UInt16.max)), 1)
            let targetSize = (columns: targetColumns, rows: targetRows)
            lastKnownSurfaceSize = targetSize
            guard let session else {
                notifySurfaceCellSizeIfChanged()
                return false
            }

            ghostty_session_set_grid_size(session, UInt16(targetColumns), UInt16(targetRows))
            _ = hostPTY?.resizeCellGrid(columns: targetColumns, rows: targetRows)
            ghostty_session_refresh(session)
            GhosttyEmbeddedAppService.shared.tick()

            for _ in 0..<5 {
                let measured = ghostty_session_size(session)
                guard measured.columns > 0, measured.rows > 0 else { break }
                if Int(measured.columns) == targetColumns, Int(measured.rows) == targetRows {
                    notifySurfaceCellSizeIfChanged()
                    return true
                }

                let currentWidth = measured.width_px > 0 ? measured.width_px : max(UInt32(targetColumns) * max(measured.cell_width_px, 9), 1)
                let currentHeight = measured.height_px > 0 ? measured.height_px : max(UInt32(targetRows) * max(measured.cell_height_px, 18), 1)
                let widthScale = Double(targetColumns) / Double(measured.columns)
                let heightScale = Double(targetRows) / Double(measured.rows)
                let nextWidth = UInt32(max((Double(currentWidth) * widthScale).rounded(), 1))
                let nextHeight = UInt32(max((Double(currentHeight) * heightScale).rounded(), 1))
                ghostty_session_set_size(session, nextWidth, nextHeight)
                ghostty_session_refresh(session)
                GhosttyEmbeddedAppService.shared.tick()
            }

            notifySurfaceCellSizeIfChanged()
            guard let resolvedSize = surfaceCellSize() else { return false }
            return resolvedSize.columns == targetColumns && resolvedSize.rows == targetRows
        }

        @discardableResult func sendScroll(
            horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32 = 0, pointerPosition: TerminalScrollPointerPosition? = nil
        ) -> Bool {
            guard let session, let surface else { return false }
            debugLastScrollModsValue = scrollMods
            if let pointerPosition {
                guard pointerPosition.isValid else { return false }
                let size = ghostty_session_size(session)
                let widthPixels = max(Double(size.width_px), 1)
                let heightPixels = max(Double(size.height_px), 1)
                let xPixels = min(pointerPosition.x * widthPixels, widthPixels - 1)
                let yPixels = min(pointerPosition.y * heightPixels, heightPixels - 1)
                ghostty_surface_mouse_pos(
                    surface, xPixels / surfaceScaleFactor, yPixels / surfaceScaleFactor, ghostty_input_mods_e(pointerPosition.mods))
            }
            ghostty_surface_mouse_scroll(surface, Double(horizontal), Double(vertical), scrollMods)
            requestSurfaceRefresh()
            return true
        }

        @discardableResult func performBindingAction(_ action: String) -> Bool {
            guard let surface else { return false }
            let performed = action.withCString { pointer in ghostty_surface_binding_action(surface, pointer, UInt(action.lengthOfBytes(using: .utf8)))
            }
            guard performed else { return false }
            GhosttyEmbeddedAppService.shared.tick()
            requestSurfaceRefresh()
            GhosttyEmbeddedAppService.shared.tick()
            return true
        }

        @discardableResult func clearScreenAndScrollback() -> Bool { performBindingAction("clear_screen") }

        func snapshot() -> GhosttyTerminalSnapshot? { GhosttyTerminalSnapshotCapture.captureFromSession(session) }

        func renderStateSnapshot() -> GhosttyTerminalSnapshotCapture.CapturedSnapshot? {
            GhosttyTerminalSnapshotCapture.captureRenderStateFromSession(session)
        }

        func snapshotText() -> String? {
            guard let snapshot = snapshot() else { return nil }
            return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot)
        }

        func sessionTitle() -> String? {
            guard let session else { return nil }
            return Self.takeString(ghostty_session_title(session))
        }

        func sessionWorkingDirectory() -> String? {
            guard let session else { return nil }
            return Self.takeString(ghostty_session_working_directory(session))
        }

        private func headlessSurfaceHostView() -> GhosttyHeadlessSessionHostView {
            if let headlessHostView { return headlessHostView }
            // NSView construction + `wantsLayer` are main-only; build the view via the legal engine→main
            // synchronous hop. The engine actor never sends it AppKit messages afterward — it only hands
            // the opaque pointer to GhosttyKit — so retaining it `nonisolated(unsafe)` is sound.
            let view = Self.mainActorSync {
                let view = GhosttyHeadlessSessionHostView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
                view.wantsLayer = true
                return view
            }
            headlessHostView = view
            return view
        }

        /// Runs `body` synchronously on the main actor from the terminal engine actor — the one legal
        /// direction of the one-way rule (AppKit view/screen affinity). Runs inline when already on main.
        private static func mainActorSync<T>(_ body: @escaping @MainActor () -> T) -> T {
            let box = GhosttyDriverMainActorSyncBox<T>()
            if Thread.isMainThread {
                MainActor.assumeIsolated { box.value = body() }
            } else {
                DispatchQueue.main.sync { MainActor.assumeIsolated { box.value = body() } }
            }
            guard let value = box.value else { preconditionFailure("main-actor driver work did not return a value") }
            return value
        }

        private func notifySurfaceCellSizeIfChanged() {
            guard let size = surfaceCellSize() else { return }
            guard lastKnownSurfaceSize?.columns != size.columns || lastKnownSurfaceSize?.rows != size.rows else {
                onSurfaceCellSizeChanged?(size.columns, size.rows)
                return
            }
            lastKnownSurfaceSize = size
            onSurfaceCellSizeChanged?(size.columns, size.rows)
        }

        private func handleSurfaceClosed() {
            guard !didHandleSurfaceClose else { return }
            didHandleSurfaceClose = true
            guard let onSurfaceClosed else {
                terminate()
                return
            }
            onSurfaceClosed()
        }

        private func handleHostPTYClosed() {
            guard !didHandleSurfaceClose else { return }
            didHandleSurfaceClose = true
            guard let onSurfaceClosed else {
                terminate()
                return
            }
            onSurfaceClosed()
        }

        private func scheduleSessionStateDelivery() {
            guard !sessionStateDeliveryScheduled else { return }
            sessionStateDeliveryScheduled = true
            Task { @TerminalEngineActor [weak self] in
                guard let self else { return }
                self.sessionStateDeliveryScheduled = false
                self.deliverSessionStateChange()
            }
        }

        private func deliverSessionStateChange(forcedFlags: GhosttyEmbeddedSessionStateChange.Flags? = nil) {
            guard let session else { return }
            let revision = ghostty_session_state_revision(session)
            let flags = forcedFlags ?? GhosttyEmbeddedSessionStateChange.Flags(rawValue: ghostty_session_take_pending_state_flags(session))
            guard !flags.isEmpty || revision != lastDeliveredSessionStateRevision else { return }
            lastDeliveredSessionStateRevision = revision
            onSessionStateChanged?(
                GhosttyEmbeddedSessionStateChange(
                    flags: flags, revision: revision, title: flags.contains(.title) ? sessionTitle() : nil,
                    workingDirectory: flags.contains(.workingDirectory) ? sessionWorkingDirectory() : nil))
        }

        private nonisolated static let surfaceDataCallback: ghostty_surface_data_cb = { userdata, bytes, len in
            guard let userdata, let bytes, len > 0 else { return }
            let runtime = Unmanaged<GhosttyEmbeddedTerminalSessionDriver>.fromOpaque(userdata).takeUnretainedValue()
            runtime.handoffOutputDeliveryFence.beginDelivery()
            defer { runtime.handoffOutputDeliveryFence.finishDelivery() }
            if runtime.outputHandler == nil { return }
            let data = Data(bytes: bytes, count: Int(len))
            runtime.outputHandler?(data)
        }

        private nonisolated static let sessionStateCallback: ghostty_session_state_cb = { userdata, _ in
            guard let userdata else { return }
            let runtime = Unmanaged<GhosttyEmbeddedTerminalSessionDriver>.fromOpaque(userdata).takeUnretainedValue()
            Task { @TerminalEngineActor in runtime.scheduleSessionStateDelivery() }
        }

        private nonisolated static let hostManagedReceiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, bytes, len in
            guard let userdata, let bytes, len > 0 else { return }
            let hostPTY = Unmanaged<HostManagedPTYTerminalSessionDriver>.fromOpaque(userdata).takeUnretainedValue()
            hostPTY.sendRawBytes(Data(bytes: bytes, count: len))
        }

        private nonisolated static let hostManagedReceiveResizeCallback: ghostty_surface_receive_resize_cb = {
            userdata, columns, rows, pixelWidth, pixelHeight in
            guard let userdata, columns > 0, rows > 0 else { return }
            let hostPTY = Unmanaged<HostManagedPTYTerminalSessionDriver>.fromOpaque(userdata).takeUnretainedValue()
            _ = hostPTY.resizeCellGrid(columns: Int(columns), rows: Int(rows), pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }

        private static func takeString(_ raw: ghostty_string_s) -> String? {
            defer { ghostty_string_free(raw) }
            guard let pointer = raw.ptr else { return nil }
            let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(pointer), count: Int(raw.len))
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Carries a main-actor-produced value back across `DispatchQueue.main.sync` into the engine actor.
    private final class GhosttyDriverMainActorSyncBox<T>: @unchecked Sendable { var value: T? }
#endif
