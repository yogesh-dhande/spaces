import AppKit
import Carbon
import Foundation
import GhosttyKit
import spacesterminalcore

@MainActor private final class GhosttyMirrorSurfaceHostView: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }

@MainActor final class GhosttyMirrorTerminalView: NSView {
    typealias SendTextHandler = @MainActor (String) -> Void
    typealias SendKeyHandler = @MainActor (String) -> Void
    typealias SendScrollHandler = @MainActor (CGFloat, CGFloat) -> Void
    typealias ViewportSizeHandler = @MainActor (Int, Int) -> Void

    private struct SurfaceGeometry: Equatable {
        let width: UInt32
        let height: UInt32
        let scale: Double
        let displayID: UInt32?
        let windowNumber: Int?
    }

    private struct CellMetrics: Equatable {
        let width: CGFloat
        let height: CGFloat
    }

    private static let defaultFontSize: CGFloat = 12

    private let launchConfiguration: TerminalSessionLaunchConfiguration
    private let surfaceHostView = GhosttyMirrorSurfaceHostView(frame: .zero)
    private var mirror: ghostty_mirror_t?
    private var latestFrame: GhosttyRenderFrame?
    private var renderStateKey = ""
    private var lastGeometry: SurfaceGeometry?
    private var lastReportedViewportSize: (columns: Int, rows: Int)?
    private var renderedText = ""

    var acceptsTerminalInput = false { didSet { updateSurfaceFocus() } }
    var onSendText: SendTextHandler?
    var onSendKey: SendKeyHandler?
    var onSendScroll: SendScrollHandler?
    var onViewportSizeChanged: ViewportSizeHandler?

    init(launchConfiguration: TerminalSessionLaunchConfiguration) {
        self.launchConfiguration = launchConfiguration
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        installSurfaceHostView()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { MainActor.assumeIsolated { if let mirror { ghostty_mirror_free(mirror) } } }

    override var acceptsFirstResponder: Bool { acceptsTerminalInput }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var hasRenderedContent: Bool { latestFrame != nil && mirror != nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            lastGeometry = nil
            updateSurfaceFocus()
            return
        }
        ensureMirrorIfNeeded()
        updateSurfaceGeometry()
        reportViewportSizeIfNeeded()
        applyLatestFrameIfPossible()
        updateSurfaceFocus()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        ensureMirrorIfNeeded()
        updateSurfaceGeometry()
        reportViewportSizeIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceGeometry()
    }

    override func mouseDown(with event: NSEvent) {
        focusWindow()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        focusWindow()
        super.rightMouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let horizontal = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX * 2 : event.scrollingDeltaX
        let vertical = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 2 : event.scrollingDeltaY
        onSendScroll?(horizontal, vertical)
    }

    override func keyDown(with event: NSEvent) {
        guard canProcessTerminalInput else {
            super.keyDown(with: event)
            return
        }
        if GhosttyTerminalInputTranslator.shouldDeferToSystemShortcut(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
            super.keyDown(with: event)
            return
        }
        if let keySpec = Self.remoteKeySpecifier(for: event) {
            onSendKey?(keySpec)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if let characters = GhosttyTerminalInputTranslator.ghosttyText(for: event), !characters.isEmpty {
            onSendText?(characters)
            return
        }
        super.keyDown(with: event)
    }

    func update(frame: GhosttyRenderFrame?, renderStateKey: String) {
        if self.renderStateKey != renderStateKey { renderedText = "" }
        self.renderStateKey = renderStateKey
        latestFrame = frame
        renderedText = frame.map { GhosttyTerminalSnapshotGrid.fullPlainText(for: $0.snapshot) } ?? ""
        ensureMirrorIfNeeded()
        applyLatestFrameIfPossible()
    }

    func update(snapshot: GhosttyTerminalSnapshot?, renderStateKey: String) {
        let frame = snapshot.map { GhosttyRenderFrame(sessionRevision: nil, ownerEpoch: 0, snapshot: $0) }
        update(frame: frame, renderStateKey: renderStateKey)
    }

    func snapshot() -> GhosttyTerminalSnapshot? {
        if let surface = mirrorSurface(), let captured = GhosttyTerminalSnapshotCapture.captureFromSurface(surface) { return captured }
        return latestFrame?.snapshot
    }

    func snapshotText() -> String? {
        if let surfaceText = GhosttyTerminalSnapshotCapture.captureText(from: mirrorSurface()), !surfaceText.isEmpty { return surfaceText }
        if !renderedText.isEmpty { return renderedText }
        guard let snapshot = latestFrame?.snapshot else { return nil }
        return GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot)
    }

    func renderedSnapshotText() -> String? { snapshotText() }
    var hasRenderedSurfaceContent: Bool { latestFrame != nil }

    func surfaceCellSize() -> (columns: Int, rows: Int)? {
        ensureMirrorIfNeeded()
        updateSurfaceGeometry()
        if let surface = mirrorSurface() {
            let size = ghostty_surface_size(surface)
            if size.columns > 0, size.rows > 0 { return (Int(size.columns), Int(size.rows)) }
        }
        let metrics = cellMetrics()
        guard bounds.width > 0, bounds.height > 0, metrics.width > 0, metrics.height > 0 else { return nil }
        return (max(Int(floor(bounds.width / metrics.width)), 1), max(Int(floor(bounds.height / metrics.height)), 1))
    }

    func copySelectionToPasteboard() -> Bool { GhosttyClipboardBridge.copySelection(from: mirrorSurface()) }

    func pasteClipboardContents() -> Bool {
        guard acceptsTerminalInput else { return false }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
        onSendText?(text)
        return true
    }

    @discardableResult func sendScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool {
        onSendScroll?(horizontal, vertical)
        return true
    }

    func focusWindow(_ window: NSWindow?) {
        guard let window else { return }
        if window.firstResponder !== self { window.makeFirstResponder(self) }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        updateSurfaceFocus()
    }

    func releaseSurface() {
        if let mirror {
            ghostty_mirror_free(mirror)
            self.mirror = nil
        }
        latestFrame = nil
        renderedText = ""
        lastGeometry = nil
        removeFromSuperview()
    }

    private var canProcessTerminalInput: Bool { acceptsTerminalInput && window?.isKeyWindow == true && window?.firstResponder === self }

    private func focusWindow() { focusWindow(window) }

    private func installSurfaceHostView() {
        surfaceHostView.translatesAutoresizingMaskIntoConstraints = false
        surfaceHostView.wantsLayer = true
        addSubview(surfaceHostView, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            surfaceHostView.topAnchor.constraint(equalTo: topAnchor), surfaceHostView.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceHostView.trailingAnchor.constraint(equalTo: trailingAnchor), surfaceHostView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func ensureMirrorIfNeeded() {
        guard mirror == nil, window != nil else { return }
        do {
            try GhosttyEmbeddedAppService.shared.startIfNeeded()
            guard let app = GhosttyEmbeddedAppService.shared.app else { throw GhosttyEmbeddedAppServiceError.configuration("ghostty app missing") }
            var host = makeSurfaceHost()
            var config = ghostty_session_config_new()
            config.surface.platform_tag = host.platform_tag
            config.surface.platform = host.platform
            config.surface.scale_factor = host.scale_factor
            config.surface.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
            config.surface.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
            config.parked_host = host
            mirror = ghostty_mirror_new(app, &host, &config)
            guard mirror != nil else { throw GhosttyEmbeddedAppServiceError.configuration("ghostty_mirror_new failed") }
            lastGeometry = nil
            updateSurfaceGeometry()
            updateSurfaceFocus()
        } catch { fputs("spaces: ghostty mirror creation failed for session \(launchConfiguration.sessionID): \(error)\n", stderr) }
    }

    private func makeSurfaceHost() -> ghostty_surface_host_s {
        var host = ghostty_surface_host_s()
        host.platform_tag = GHOSTTY_PLATFORM_MACOS
        host.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(surfaceHostView).toOpaque()))
        host.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        return host
    }

    private func mirrorSurface() -> ghostty_surface_t? {
        guard let mirror else { return nil }
        return ghostty_mirror_surface(mirror)
    }

    private func updateSurfaceGeometry() {
        guard let mirror, let surface = mirrorSurface(), let backingSize = backingPixelSize() else { return }
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        let displayID = (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let geometry = SurfaceGeometry(
            width: backingSize.width, height: backingSize.height, scale: scale, displayID: displayID, windowNumber: window?.windowNumber)
        guard geometry != lastGeometry else { return }

        var host = makeSurfaceHost()
        _ = ghostty_mirror_set_host(mirror, &host)
        ghostty_surface_set_content_scale(surface, scale, scale)
        if let displayID { ghostty_surface_set_display_id(surface, displayID) }
        ghostty_surface_set_size(surface, geometry.width, geometry.height)
        ghostty_surface_set_occlusion(surface, window?.occlusionState.contains(.visible) ?? true)
        ghostty_surface_refresh(surface)
        lastGeometry = geometry
    }

    private func backingPixelSize() -> (width: UInt32, height: UInt32)? {
        let size = convertToBacking(bounds).size
        let width = Int(floor(size.width))
        let height = Int(floor(size.height))
        guard width > 0, height > 0 else { return nil }
        return (UInt32(width), UInt32(height))
    }

    private func updateSurfaceFocus() {
        guard let surface = mirrorSurface() else { return }
        ghostty_surface_set_focus(surface, canProcessTerminalInput)
        ghostty_surface_refresh(surface)
    }

    private func reportViewportSizeIfNeeded() {
        guard let size = surfaceCellSize() else { return }
        guard lastReportedViewportSize?.columns != size.columns || lastReportedViewportSize?.rows != size.rows else { return }
        lastReportedViewportSize = size
        onViewportSizeChanged?(size.columns, size.rows)
    }

    private func applyLatestFrameIfPossible() {
        guard let mirror, let frame = latestFrame else { return }
        updateSurfaceGeometry()
        let applyStartedAt = Date()
        let applied = withCFrame(frame) { cFrame in ghostty_mirror_apply_render_frame(mirror, cFrame) }
        let applyMS = TerminalPerformance.elapsedMS(since: applyStartedAt)
        let attributes = GhosttyRenderFrameMetrics.attributes(
            frame: frame, dropped: !applied, dropReason: applied ? nil : "mirror_apply_failed", renderMode: "ghostty-mirror",
            targetRevision: frame.sessionRevision, appliedRevision: applied ? frame.sessionRevision : nil, applyMS: applyMS)
        SpacesMobileTerminalPerformanceLogger.emit(
            .init(
                sessionID: launchConfiguration.sessionID, source: "mac-mirror", name: "render_frame_mirror_apply", elapsedMS: applyMS,
                attributes: attributes))
        TerminalPerformance.logMetric(
            "terminal_render_frame_mirror_apply", target: "session=\(launchConfiguration.sessionID)", elapsedMS: applyMS, success: applied,
            detail: GhosttyRenderFrameMetrics.detailString(attributes))
        guard applied else {
            fputs("spaces: ghostty mirror frame apply failed for session \(launchConfiguration.sessionID)\n", stderr)
            return
        }
        if let surface = mirrorSurface() { ghostty_surface_refresh(surface) }
    }

    private func withCFrame(_ frame: GhosttyRenderFrame, _ body: (UnsafePointer<ghostty_render_frame_s>) -> Bool) -> Bool {
        guard frame.version == GhosttyRenderFrame.currentVersion else { return false }
        let snapshot = frame.snapshot
        guard snapshot.columns > 0, snapshot.rows > 0, snapshot.columns <= Int(UInt16.max), snapshot.rows <= Int(UInt16.max) else { return false }
        var cells = snapshot.cells.map { cell in
            ghostty_terminal_snapshot_cell_s(
                codepoint: cell.codepoint, foreground_rgb: cell.foregroundRGB, background_rgb: cell.backgroundRGB, flags: cell.flags)
        }
        return cells.withUnsafeMutableBufferPointer { buffer in
            var cSnapshot = ghostty_terminal_snapshot_s()
            cSnapshot.columns = UInt16(snapshot.columns)
            cSnapshot.rows = UInt16(snapshot.rows)
            cSnapshot.cursor_column = UInt16(clamping: snapshot.cursorColumn)
            cSnapshot.cursor_row = UInt16(clamping: snapshot.cursorRow)
            cSnapshot.cursor_visible = snapshot.cursorVisible
            cSnapshot.default_foreground_rgb = snapshot.defaultForegroundRGB
            cSnapshot.default_background_rgb = snapshot.defaultBackgroundRGB
            cSnapshot.cell_count = buffer.count
            cSnapshot.cells = buffer.baseAddress

            var cFrame = ghostty_render_frame_s()
            cFrame.version = UInt32(frame.version)
            cFrame.session_revision = frame.sessionRevision ?? 0
            cFrame.owner_epoch = frame.ownerEpoch
            cFrame.columns = UInt16(snapshot.columns)
            cFrame.rows = UInt16(snapshot.rows)
            cFrame.snapshot = cSnapshot
            return withUnsafePointer(to: &cFrame, body)
        }
    }

    private func cellMetrics() -> CellMetrics {
        let font = NSFont.monospacedSystemFont(ofSize: Self.defaultFontSize, weight: .regular)
        let width = ceil(("W" as NSString).size(withAttributes: [.font: font]).width)
        let height = ceil(font.ascender - font.descender + font.leading)
        return CellMetrics(width: max(width, 1), height: max(height, 1))
    }

    static func remoteKeySpecifier(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let semanticFlags = flags.subtracting([.function, .numericPad])
        if let fallback = GhosttyTerminalInputTranslator.rawKeyFallbackSpecifier(for: event) { return fallback }
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "enter"
        case kVK_ANSI_K where semanticFlags == [.command]: return "ctrl+l"
        case kVK_Delete where semanticFlags == [.command]: return "ctrl+u"
        case kVK_Delete where semanticFlags == [.option]: return "ctrl+w"
        case kVK_Delete: return "backspace"
        case kVK_Escape: return "esc"
        case kVK_Tab where flags == [.shift]: return "backtab"
        case kVK_Tab: return "tab"
        default: break
        }
        if flags.contains(.control), let flag = controlKeySpecifier(for: event), !flags.contains(.command), !flags.contains(.option) { return flag }
        return nil
    }

    private static func controlKeySpecifier(for event: NSEvent) -> String? {
        guard let flaglessCharacters = event.charactersIgnoringModifiers, flaglessCharacters.count == 1,
            let scalar = flaglessCharacters.unicodeScalars.first
        else { return nil }
        guard scalar.properties.isAlphabetic else { return nil }
        return "ctrl+\(String(scalar).lowercased())"
    }
}
