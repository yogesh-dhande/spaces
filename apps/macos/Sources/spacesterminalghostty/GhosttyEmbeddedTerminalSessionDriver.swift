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

    @MainActor final class GhosttyEmbeddedTerminalSessionDriver {
        private let launchConfiguration: TerminalSessionLaunchConfiguration

        private var session: ghostty_session_t?
        private var hostPTY: HostManagedPTYTerminalSessionDriver?
        private var headlessHostView: GhosttyHeadlessSessionHostView?
        private var surfaceUserData: GhosttyEmbeddedSurfaceUserData?
        private let outputPipe = GhosttyHostManagedOutputPipe()
        private nonisolated(unsafe) var outputHandler: (@Sendable (Data) -> Void)?
        private var didHandleSurfaceClose = false
        private var lastKnownSurfaceSize: (columns: Int, rows: Int)?
        private var lastDeliveredSessionStateRevision: UInt64 = 0
        private var sessionStateDeliveryScheduled = false
        private var debugRefreshRequestCountValue = 0
        private var debugLastScrollModsValue: Int32 = 0

        var onActionEvent: (@MainActor (GhosttyActionEvent) -> Void)?
        var onSurfaceClosed: (@MainActor () -> Void)?
        var onSurfaceCellSizeChanged: (@MainActor (Int, Int) -> Void)?
        var onSessionStateChanged: (@MainActor (GhosttyEmbeddedSessionStateChange) -> Void)?

        init(launchConfiguration: TerminalSessionLaunchConfiguration) { self.launchConfiguration = launchConfiguration }

        deinit { MainActor.assumeIsolated { if session != nil || hostPTY != nil { terminate() } } }

        var surface: ghostty_surface_t? {
            guard let session else { return nil }
            return ghostty_session_surface(session)
        }

        var debugRefreshRequestCount: Int { debugRefreshRequestCountValue }
        var debugLastScrollMods: Int32 { debugLastScrollModsValue }

        func setOutputHandler(_ handler: (@Sendable (Data) -> Void)?) { outputHandler = handler }

        func startIfNeeded() throws {
            guard session == nil, hostPTY == nil else { return }

            try GhosttyEmbeddedAppService.shared.startIfNeeded()
            guard let app = GhosttyEmbeddedAppService.shared.app else { throw GhosttyEmbeddedAppServiceError.configuration("ghostty app missing") }

            let hostPTY = HostManagedPTYTerminalSessionDriver(launchConfiguration: launchConfiguration)
            let hostView = headlessSurfaceHostView()
            let scaleFactor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)

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
            outputPipe.setSession(createdSession)
            didHandleSurfaceClose = false
            ghostty_session_set_data_callback(createdSession, Self.surfaceDataCallback, Unmanaged.passUnretained(self).toOpaque())
            ghostty_session_set_state_callback(createdSession, Self.sessionStateCallback, Unmanaged.passUnretained(self).toOpaque())
            if let surface = surface {
                GhosttyEmbeddedAppService.shared.registerActionHandler(for: surface) { [weak self] event in self?.onActionEvent?(event) }
            }
            hostPTY.setOutputHandler { [weak self, outputPipe] data in
                outputPipe.process(data)
                Task { @MainActor [weak self] in
                    GhosttyEmbeddedAppService.shared.tick()
                    self?.deliverSessionStateChange()
                }
            }
            hostPTY.setSessionClosedHandler { [weak self] in self?.handleHostPTYClosed() }

            do { try hostPTY.startIfNeeded() } catch {
                hostPTY.setOutputHandler(nil)
                hostPTY.setSessionClosedHandler(nil)
                self.hostPTY = nil
                outputPipe.setSession(nil)
                ghostty_session_set_data_callback(createdSession, nil, nil)
                ghostty_session_set_state_callback(createdSession, nil, nil)
                if let surface = surface { GhosttyEmbeddedAppService.shared.unregisterActionHandler(for: surface) }
                session = nil
                self.surfaceUserData = nil
                ghostty_session_free(createdSession)
                throw error
            }

            ghostty_session_set_focus(createdSession, false)
            ghostty_session_set_occlusion(createdSession, true)
            let initialSize = lastKnownSurfaceSize ?? hostPTY.surfaceCellSize()
            _ = resizeCellGrid(columns: initialSize.columns, rows: initialSize.rows)
            ghostty_session_refresh(createdSession)
            deliverSessionStateChange(forcedFlags: .allKnown)
            notifySurfaceCellSizeIfChanged()
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

        @discardableResult func sendScroll(horizontal: CGFloat, vertical: CGFloat, scrollMods: Int32 = 0) -> Bool {
            guard let surface else { return false }
            debugLastScrollModsValue = scrollMods
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
            let view = GhosttyHeadlessSessionHostView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            view.wantsLayer = true
            headlessHostView = view
            return view
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
            Task { @MainActor [weak self] in
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
            if runtime.outputHandler == nil { return }
            let data = Data(bytes: bytes, count: Int(len))
            runtime.outputHandler?(data)
        }

        private nonisolated static let sessionStateCallback: ghostty_session_state_cb = { userdata, _ in
            guard let userdata else { return }
            let runtime = Unmanaged<GhosttyEmbeddedTerminalSessionDriver>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in runtime.scheduleSessionStateDelivery() }
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
#endif
