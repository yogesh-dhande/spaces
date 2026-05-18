import AppKit
import Foundation
import GhosttyKit
import spacesterminalcore

@MainActor private final class GhosttyEmbeddedSessionHostView: NSView {}

@MainActor final class GhosttyEmbeddedTerminalSessionDriver {
    private let launchConfiguration: TerminalSessionLaunchConfiguration

    private var session: ghostty_session_t?
    private var hiddenHostWindow: NSWindow?
    private weak var hiddenHostView: GhosttyEmbeddedSessionHostView?
    private var surfaceUserData: GhosttyEmbeddedSurfaceUserData?
    private nonisolated(unsafe) var outputHandler: (@Sendable (Data) -> Void)?
    private var didHandleSurfaceClose = false
    private var lastKnownSurfaceSize: (columns: Int, rows: Int)?

    var onActionEvent: (@MainActor (GhosttyActionEvent) -> Void)?
    var onSurfaceClosed: (@MainActor () -> Void)?
    var onSurfaceCellSizeChanged: (@MainActor (Int, Int) -> Void)?

    init(launchConfiguration: TerminalSessionLaunchConfiguration) { self.launchConfiguration = launchConfiguration }

    deinit { MainActor.assumeIsolated { if session != nil { terminate() } } }

    var surface: ghostty_surface_t? {
        guard let session else { return nil }
        return ghostty_session_surface(session)
    }

    func setOutputHandler(_ handler: (@Sendable (Data) -> Void)?) { outputHandler = handler }

    func startIfNeeded() throws {
        guard session == nil else { return }

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

        if let command = launchConfiguration.command, let wrapped = strdup(Self.loginShellCommand(shell: launchConfiguration.shell, command: command))
        {
            allocatedStrings.append(wrapped)
            sessionConfig.surface.command = UnsafePointer(wrapped)
            sessionConfig.surface.wait_after_command = false
        }

        let workingDirectory = launchConfiguration.workingDirectory
        let createdSession = workingDirectory.withCString { cwd in
            sessionConfig.surface.working_directory = cwd
            return ghostty_session_new(app, &sessionConfig)
        }
        guard let createdSession else { throw GhosttyEmbeddedAppServiceError.configuration("ghostty_session_new failed") }

        session = createdSession
        didHandleSurfaceClose = false
        ghostty_session_set_data_callback(createdSession, Self.surfaceDataCallback, Unmanaged.passUnretained(self).toOpaque())
        if let surface = surface {
            GhosttyEmbeddedAppService.shared.registerActionHandler(for: surface) { [weak self] event in self?.onActionEvent?(event) }
        }

        ghostty_session_set_focus(createdSession, false)
        ghostty_session_set_occlusion(createdSession, true)
        ghostty_session_set_size(createdSession, 960, 640)
        ghostty_session_refresh(createdSession)
        notifySurfaceCellSizeIfChanged()
    }

    func terminate() {
        guard let session else { return }
        let surface = ghostty_session_surface(session)
        GhosttyEmbeddedAppService.shared.unregisterActionHandler(for: surface)
        ghostty_session_set_data_callback(session, nil, nil)
        self.session = nil
        self.surfaceUserData = nil
        ghostty_session_free(session)
        lastKnownSurfaceSize = nil
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
        guard let session else { return }
        ghostty_session_refresh(session)
    }

    func sendRawBytes(_ data: Data) {
        guard let session, !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_session_send_input_raw(session, baseAddress, UInt(data.count))
        }
        requestSurfaceRefresh()
    }

    func foregroundPID() -> Int32? {
        guard let session else { return nil }
        let pid = ghostty_session_foreground_pid(session)
        guard pid > 0 else { return nil }
        return Int32(pid)
    }

    func surfaceCellSize() -> (columns: Int, rows: Int)? {
        guard let session else { return lastKnownSurfaceSize }
        let size = ghostty_session_size(session)
        guard size.columns > 0, size.rows > 0 else { return lastKnownSurfaceSize }
        let resolved = (columns: Int(size.columns), rows: Int(size.rows))
        lastKnownSurfaceSize = resolved
        return resolved
    }

    func setFocused(_ focused: Bool) {
        guard let session else { return }
        ghostty_session_set_focus(session, focused)
    }

    func setOccluded(_ occluded: Bool) {
        guard let session else { return }
        ghostty_session_set_occlusion(session, occluded)
    }

    func updateGeometry(width: UInt32, height: UInt32, scale: Double, displayID: UInt32?) {
        guard let session else { return }
        ghostty_session_set_content_scale(session, scale, scale)
        if let displayID { ghostty_session_set_display_id(session, displayID) }
        ghostty_session_set_size(session, width, height)
        notifySurfaceCellSizeIfChanged()
    }

    func snapshot() -> GhosttyTerminalSnapshot? {
        guard let session else { return nil }
        return GhosttyTerminalSnapshotCapture.captureFromSession(session)
    }

    func snapshotText() -> String? {
        guard let surface else { return nil }
        return GhosttyTerminalSnapshotCapture.captureText(from: surface)
    }

    func copySelectionToPasteboard() -> Bool { GhosttyClipboardBridge.copySelection(from: surface) }

    func pasteClipboardContents() -> Bool {
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

    private static func loginShellCommand(shell: String, command: String) -> String {
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
}
