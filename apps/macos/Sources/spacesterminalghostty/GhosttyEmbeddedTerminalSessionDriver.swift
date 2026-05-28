import AppKit
import Foundation
import GhosttyKit
import spacesterminalcore

@MainActor private final class GhosttyEmbeddedSessionHostView: NSView {}

@MainActor final class GhosttyEmbeddedTerminalSessionDriver {
    private let launchConfiguration: TerminalSessionLaunchConfiguration
    private let allowsPTYFallback: Bool

    private var session: ghostty_session_t?
    private var fallbackPTY: FallbackPTYTerminalSessionDriver?
    private var hiddenHostWindow: NSWindow?
    private weak var hiddenHostView: GhosttyEmbeddedSessionHostView?
    private var surfaceUserData: GhosttyEmbeddedSurfaceUserData?
    private nonisolated(unsafe) var outputHandler: (@Sendable (Data) -> Void)?
    private var didHandleSurfaceClose = false
    private var lastKnownSurfaceSize: (columns: Int, rows: Int)?
    private var lastKnownPixelSize: (width: UInt32, height: UInt32)?
    private var lastDeliveredSessionStateRevision: UInt64 = 0
    private var sessionStateDeliveryScheduled = false

    var onActionEvent: (@MainActor (GhosttyActionEvent) -> Void)?
    var onSurfaceClosed: (@MainActor () -> Void)?
    var onSurfaceCellSizeChanged: (@MainActor (Int, Int) -> Void)?
    var onSessionStateChanged: (@MainActor (GhosttyEmbeddedSessionStateChange) -> Void)?

    init(launchConfiguration: TerminalSessionLaunchConfiguration, allowsPTYFallback: Bool = true) {
        self.launchConfiguration = launchConfiguration
        self.allowsPTYFallback = allowsPTYFallback
    }

    deinit { MainActor.assumeIsolated { if session != nil || fallbackPTY != nil { terminate() } } }

    var surface: ghostty_surface_t? {
        guard let session else { return nil }
        return ghostty_session_surface(session)
    }
    var isUsingFallbackPTY: Bool { fallbackPTY != nil }

    func setOutputHandler(_ handler: (@Sendable (Data) -> Void)?) {
        outputHandler = handler
        fallbackPTY?.setOutputHandler(handler)
    }

    func startIfNeeded() throws {
        guard session == nil, fallbackPTY == nil else { return }

        try GhosttyEmbeddedAppService.shared.startIfNeeded()
        guard let app = GhosttyEmbeddedAppService.shared.app else { throw GhosttyEmbeddedAppServiceError.configuration("ghostty app missing") }

        let hostWindow = ensureHiddenHostWindow()
        guard let hostView = hiddenHostView else { throw GhosttyEmbeddedAppServiceError.configuration("hidden host view missing") }
        if hostWindow.isVisible { hostWindow.orderOut(nil) }

        var sessionConfig = ghostty_session_config_new()
        sessionConfig.surface.platform_tag = GHOSTTY_PLATFORM_MACOS
        sessionConfig.surface.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(hostView).toOpaque()))
        sessionConfig.surface.scale_factor = Double(hostWindow.backingScaleFactor)
        sessionConfig.surface.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        let surfaceUserData = GhosttyEmbeddedSurfaceUserData(
            closeHandler: { [weak self] in self?.handleSurfaceClosed() }, surfaceProvider: { [weak self] in self?.surface })
        self.surfaceUserData = surfaceUserData
        sessionConfig.surface.userdata = Unmanaged.passUnretained(surfaceUserData).toOpaque()

        sessionConfig.parked_host.platform_tag = GHOSTTY_PLATFORM_MACOS
        sessionConfig.parked_host.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(hostView).toOpaque()))
        sessionConfig.parked_host.scale_factor = Double(hostWindow.backingScaleFactor)

        var allocatedStrings: [UnsafeMutablePointer<CChar>] = []
        defer { for pointer in allocatedStrings { free(pointer) } }

        if let command = launchConfiguration.command, let wrapped = strdup(Self.launchCommand(shell: launchConfiguration.shell, command: command)) {
            allocatedStrings.append(wrapped)
            sessionConfig.surface.command = UnsafePointer(wrapped)
            sessionConfig.surface.wait_after_command = false
        }

        let workingDirectory = launchConfiguration.workingDirectory
        let createdSession = workingDirectory.withCString { cwd in
            sessionConfig.surface.working_directory = cwd
            return ghostty_session_new(app, &sessionConfig)
        }
        guard let createdSession else {
            if allowsPTYFallback {
                try startFallbackPTY()
                return
            }
            throw GhosttyEmbeddedAppServiceError.configuration("ghostty_session_new failed")
        }

        session = createdSession
        didHandleSurfaceClose = false
        ghostty_session_set_data_callback(createdSession, Self.surfaceDataCallback, Unmanaged.passUnretained(self).toOpaque())
        ghostty_session_set_state_callback(createdSession, Self.sessionStateCallback, Unmanaged.passUnretained(self).toOpaque())
        if let surface = surface {
            GhosttyEmbeddedAppService.shared.registerActionHandler(for: surface) { [weak self] event in self?.onActionEvent?(event) }
        }

        ghostty_session_set_focus(createdSession, false)
        ghostty_session_set_occlusion(createdSession, true)
        ghostty_session_set_size(createdSession, 960, 640)
        lastKnownPixelSize = (960, 640)
        ghostty_session_refresh(createdSession)
        deliverSessionStateChange(forcedFlags: .allKnown)
        notifySurfaceCellSizeIfChanged()
    }

    func terminate() {
        if let fallbackPTY {
            self.fallbackPTY = nil
            fallbackPTY.terminate()
            lastKnownSurfaceSize = nil
            lastKnownPixelSize = nil
            hiddenHostWindow?.orderOut(nil)
            return
        }
        guard let session else { return }
        let surface = ghostty_session_surface(session)
        GhosttyEmbeddedAppService.shared.unregisterActionHandler(for: surface)
        ghostty_session_set_data_callback(session, nil, nil)
        ghostty_session_set_state_callback(session, nil, nil)
        self.session = nil
        self.surfaceUserData = nil
        lastDeliveredSessionStateRevision = 0
        sessionStateDeliveryScheduled = false
        ghostty_session_free(session)
        lastKnownSurfaceSize = nil
        lastKnownPixelSize = nil
        hiddenHostWindow?.orderOut(nil)
    }

    func attachRenderer(_ renderer: ghostty_renderer_t?) -> Bool {
        guard let session, let renderer else { return false }
        return ghostty_renderer_attach(renderer, session)
    }

    func detachRenderer(_ renderer: ghostty_renderer_t?) -> Bool {
        guard let renderer else { return true }
        return ghostty_renderer_detach(renderer)
    }

    func updateRendererHost(_ renderer: ghostty_renderer_t?, host: inout ghostty_surface_host_s) -> Bool {
        guard let renderer else { return false }
        return ghostty_renderer_set_host(renderer, &host)
    }

    func requestSurfaceRefresh() {
        guard fallbackPTY == nil else { return }
        guard let session else { return }
        ghostty_session_refresh(session)
    }

    func sendRawBytes(_ data: Data) {
        if let fallbackPTY {
            fallbackPTY.sendRawBytes(data)
            return
        }
        guard let session, !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_session_send_input_raw(session, baseAddress, UInt(data.count))
        }
        requestSurfaceRefresh()
    }

    func processOutput(_ data: Data) {
        guard fallbackPTY == nil else { return }
        guard let session, !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_session_process_output(session, baseAddress, UInt(data.count))
        }
        requestSurfaceRefresh()
    }

    func foregroundPID() -> Int32? {
        if let fallbackPTY { return fallbackPTY.foregroundPID() }
        guard let session else { return nil }
        let pid = ghostty_session_foreground_pid(session)
        guard pid > 0 else { return nil }
        return Int32(pid)
    }

    func surfaceCellSize() -> (columns: Int, rows: Int)? {
        if let fallbackPTY { return fallbackPTY.surfaceCellSize() }
        guard let session else { return lastKnownSurfaceSize }
        let size = ghostty_session_size(session)
        guard size.columns > 0, size.rows > 0 else { return lastKnownSurfaceSize }
        let resolved = (columns: Int(size.columns), rows: Int(size.rows))
        lastKnownSurfaceSize = resolved
        return resolved
    }

    func setFocused(_ focused: Bool) {
        guard fallbackPTY == nil else { return }
        guard let session else { return }
        ghostty_session_set_focus(session, focused)
    }

    func setOccluded(_ occluded: Bool) {
        guard fallbackPTY == nil else { return }
        guard let session else { return }
        ghostty_session_set_occlusion(session, occluded)
    }

    func updateGeometry(width: UInt32, height: UInt32, scale: Double, displayID: UInt32?) {
        guard fallbackPTY == nil else { return }
        guard let session else { return }
        ghostty_session_set_content_scale(session, scale, scale)
        if let displayID { ghostty_session_set_display_id(session, displayID) }
        ghostty_session_set_size(session, width, height)
        lastKnownPixelSize = (width, height)
        syncHiddenHostWindowSize(width: width, height: height)
        notifySurfaceCellSizeIfChanged()
    }

    @discardableResult func resizeCellGrid(columns: Int, rows: Int) -> Bool {
        if let fallbackPTY { return fallbackPTY.resizeCellGrid(columns: columns, rows: rows) }
        guard let session else { return false }
        let targetColumns = max(columns, 1)
        let targetRows = max(rows, 1)
        guard let currentSize = surfaceCellSize(), currentSize.columns > 0, currentSize.rows > 0 else { return false }

        let currentPixels = lastKnownPixelSize ?? (width: 960, height: 640)
        var nextWidth = Double(currentPixels.width)
        var nextHeight = Double(currentPixels.height)

        for _ in 0..<3 {
            guard let measuredSize = surfaceCellSize(), measuredSize.columns > 0, measuredSize.rows > 0 else { break }
            let widthScale = Double(targetColumns) / Double(measuredSize.columns)
            let heightScale = Double(targetRows) / Double(measuredSize.rows)
            nextWidth = max((nextWidth * widthScale).rounded(), 1)
            nextHeight = max((nextHeight * heightScale).rounded(), 1)
            ghostty_session_set_size(session, UInt32(nextWidth), UInt32(nextHeight))
            lastKnownPixelSize = (UInt32(nextWidth), UInt32(nextHeight))
            syncHiddenHostWindowSize(width: UInt32(nextWidth), height: UInt32(nextHeight))
            ghostty_session_refresh(session)
            GhosttyEmbeddedAppService.shared.tick()
        }

        notifySurfaceCellSizeIfChanged()
        guard let resolvedSize = surfaceCellSize() else { return false }
        return resolvedSize.columns == targetColumns && resolvedSize.rows == targetRows
    }

    func preserveCurrentOwnerGeometryForParking() {
        guard fallbackPTY == nil else { return }
        guard let session else { return }
        let size = ghostty_session_size(session)
        let width = size.width_px > 0 ? size.width_px : (lastKnownPixelSize?.width ?? 0)
        let height = size.height_px > 0 ? size.height_px : (lastKnownPixelSize?.height ?? 0)
        guard width > 0, height > 0 else { return }
        lastKnownPixelSize = (width, height)
        syncHiddenHostWindowSize(width: width, height: height)
    }

    func snapshot() -> GhosttyTerminalSnapshot? { return GhosttyTerminalSnapshotCapture.captureFromSession(session) }

    func snapshotText() -> String? {
        guard fallbackPTY == nil else { return nil }
        guard let surface else { return nil }
        return GhosttyTerminalSnapshotCapture.captureText(from: surface)
    }

    func sessionTitle() -> String? {
        guard fallbackPTY == nil else { return nil }
        guard let session else { return nil }
        return Self.takeString(ghostty_session_title(session))
    }

    func sessionWorkingDirectory() -> String? {
        guard fallbackPTY == nil else { return nil }
        guard let session else { return nil }
        return Self.takeString(ghostty_session_working_directory(session))
    }

    func copySelectionToPasteboard() -> Bool { GhosttyClipboardBridge.copySelection(from: surface) }

    func pasteClipboardContents() -> Bool {
        guard fallbackPTY == nil else { return false }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
        sendRawBytes(Data(text.utf8))
        return true
    }

    private func ensureHiddenHostWindow() -> NSWindow {
        if let hiddenHostWindow { return hiddenHostWindow }

        let frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        let hostWindow = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false
        hostWindow.alphaValue = 0
        hostWindow.ignoresMouseEvents = true
        hostWindow.backgroundColor = .clear
        let hostView = GhosttyEmbeddedSessionHostView(frame: frame)
        hostView.wantsLayer = true
        hostWindow.contentView = hostView
        hostWindow.orderOut(nil)
        hiddenHostWindow = hostWindow
        hiddenHostView = hostView
        return hostWindow
    }

    private func syncHiddenHostWindowSize(width: UInt32, height: UInt32) {
        guard width > 0, height > 0 else { return }
        let hostWindow = ensureHiddenHostWindow()
        let contentSize = NSSize(width: Int(width), height: Int(height))
        if hostWindow.contentRect(forFrameRect: hostWindow.frame).size != contentSize { hostWindow.setContentSize(contentSize) }
        if let hiddenHostView, hiddenHostView.frame.size != contentSize {
            hiddenHostView.frame = NSRect(origin: .zero, size: contentSize)
            hiddenHostView.layoutSubtreeIfNeeded()
        }
    }

    private func notifySurfaceCellSizeIfChanged() {
        guard let size = surfaceCellSize() else { return }
        onSurfaceCellSizeChanged?(size.columns, size.rows)
    }

    private func handleSurfaceClosed() {
        guard !didHandleSurfaceClose else { return }
        didHandleSurfaceClose = true
        terminate()
        onSurfaceClosed?()
    }

    private func startFallbackPTY() throws {
        let fallbackPTY = FallbackPTYTerminalSessionDriver(launchConfiguration: launchConfiguration)
        fallbackPTY.setOutputHandler(outputHandler)
        fallbackPTY.setSessionClosedHandler { [weak self] in self?.handleFallbackPTYClosed() }
        try fallbackPTY.startIfNeeded()
        self.fallbackPTY = fallbackPTY
        lastKnownSurfaceSize = fallbackPTY.surfaceCellSize()
        notifySurfaceCellSizeIfChanged()
    }

    private func handleFallbackPTYClosed() {
        guard !didHandleSurfaceClose else { return }
        didHandleSurfaceClose = true
        fallbackPTY = nil
        lastKnownSurfaceSize = nil
        lastKnownPixelSize = nil
        hiddenHostWindow?.orderOut(nil)
        onSurfaceClosed?()
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

    nonisolated static func launchCommand(shell: String, command: String) -> String {
        if command.hasPrefix("direct:") || command.hasPrefix("shell:") { return command }
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        return "\(shell) -l -c '\(escaped)'"
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

    private static func takeString(_ raw: ghostty_string_s) -> String? {
        defer { ghostty_string_free(raw) }
        guard let pointer = raw.ptr else { return nil }
        let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(pointer), count: Int(raw.len))
        return String(decoding: bytes, as: UTF8.self)
    }
}
