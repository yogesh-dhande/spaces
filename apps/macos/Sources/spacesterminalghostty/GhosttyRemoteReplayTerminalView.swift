import AppKit
import Carbon
import Foundation
import GhosttyKit
import spacesterminalcore

@MainActor private final class GhosttyRemoteReplaySurfaceHostView: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }

@MainActor final class GhosttyRemoteReplayTerminalView: NSView {
    typealias SendTextHandler = @MainActor (String) -> Void
    typealias SendKeyHandler = @MainActor (String) -> Void
    typealias ViewportSizeHandler = @MainActor (Int, Int) -> Void

    private struct SurfaceGeometry: Equatable {
        let width: UInt32
        let height: UInt32
        let scale: Double
        let displayID: UInt32?
    }

    private struct PixelSize: Equatable {
        let width: UInt32
        let height: UInt32
    }

    private static let carrierCommand = "direct:/bin/cat"

    private let launchConfiguration: TerminalSessionLaunchConfiguration
    private let sessionDriver: GhosttyEmbeddedTerminalSessionDriver
    private var renderer: ghostty_renderer_t?
    private var pendingSurfaceCreation = false
    private var surfaceCreationRetryWorkItem: DispatchWorkItem?
    private var nextSurfaceCreationRetryAt: Date?
    private var lastSurfaceCreationFailureMessage: String?
    private var surfaceHostView = GhosttyRemoteReplaySurfaceHostView(frame: .zero)
    private var boundSurfaceWindowNumber: Int?
    private var lastGeometry: SurfaceGeometry?
    private var lastFocused: Bool?
    private var lastOccluded: Bool?
    private var trackingArea: NSTrackingArea?
    private weak var observedWindow: NSWindow?
    private var previousAcceptsMouseMovedEvents: Bool?
    private var isWindowVisible = true
    private var lastSnapshot: GhosttyTerminalSnapshot?
    private var lastViewportSnapshot: GhosttyTerminalSnapshot?
    private var lastReplayPixelSize: PixelSize?
    private var lastReplayStateKey: String?
    private var lastRenderedText: String?

    var acceptsTerminalInput = false
    var onSendText: SendTextHandler?
    var onSendKey: SendKeyHandler?
    var onViewportSizeChanged: ViewportSizeHandler?

    init(launchConfiguration: TerminalSessionLaunchConfiguration) {
        self.launchConfiguration = launchConfiguration
        sessionDriver = GhosttyEmbeddedTerminalSessionDriver(launchConfiguration: Self.replayLaunchConfiguration(from: launchConfiguration))
        super.init(frame: .zero)
        wantsLayer = true
        installSurfaceHostView(surfaceHostView)
        sessionDriver.onSurfaceClosed = { [weak self] in self?.handleSurfaceClosed() }
        sessionDriver.onSurfaceCellSizeChanged = { [weak self] columns, rows in self?.onViewportSizeChanged?(columns, rows) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        MainActor.assumeIsolated {
            teardownWindowObservation()
            surfaceCreationRetryWorkItem?.cancel()
            if let renderer { ghostty_renderer_free(renderer) }
        }
    }

    override var acceptsFirstResponder: Bool { acceptsTerminalInput }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var surface: ghostty_surface_t? { sessionDriver.rendererSurface(renderer) ?? sessionDriver.surface }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        teardownWindowObservation()

        guard let window else { return }
        observedWindow = window
        createSurfaceIfNeeded()
        rebindSurfaceHostIfNeeded()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWindowDidChangeScreen(_:)), name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWindowDidChangeOcclusionState(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWindowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWindowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: window)

        if previousAcceptsMouseMovedEvents == nil { previousAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents }
        window.acceptsMouseMovedEvents = true

        updateSurfaceGeometry()
        updateWindowVisibility()
        setSurfaceFocus(window.isKeyWindow && window.firstResponder === self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .enabledDuringMouseDrag]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if pendingSurfaceCreation { createSurfaceIfNeeded() }
        updateSurfaceGeometry()
        replayLatestSnapshotIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceGeometry()
        replayLatestSnapshotIfNeeded()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { setSurfaceFocus(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { setSurfaceFocus(false) }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        focusWindow()
        _ = sendMousePosition(for: event)
        _ = sendMouseButton(event: event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
        requestSurfaceRefresh()
    }

    override func mouseUp(with event: NSEvent) {
        _ = sendMousePosition(for: event)
        _ = sendMouseButton(event: event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
        requestSurfaceRefresh()
    }

    override func rightMouseDown(with event: NSEvent) {
        focusWindow()
        _ = sendMousePosition(for: event)
        if sendMouseButton(event: event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT) {
            requestSurfaceRefresh()
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        _ = sendMousePosition(for: event)
        if sendMouseButton(event: event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT) {
            requestSurfaceRefresh()
            return
        }
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        focusWindow()
        _ = sendMousePosition(for: event)
        _ = sendMouseButton(event: event, state: GHOSTTY_MOUSE_PRESS, button: mouseButton(for: event))
        requestSurfaceRefresh()
    }

    override func otherMouseUp(with event: NSEvent) {
        _ = sendMousePosition(for: event)
        _ = sendMouseButton(event: event, state: GHOSTTY_MOUSE_RELEASE, button: mouseButton(for: event))
        requestSurfaceRefresh()
    }

    override func mouseMoved(with event: NSEvent) {
        if sendMousePosition(for: event) {
            if shouldRefreshSurfaceAfterMousePositionChange() { requestSurfaceRefresh() }
            return
        }
        super.mouseMoved(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if sendMousePosition(for: event) {
            requestSurfaceRefresh()
            return
        }
        super.mouseDragged(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        if sendMousePosition(for: event) {
            requestSurfaceRefresh()
            return
        }
        super.rightMouseDragged(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        if sendMousePosition(for: event) {
            requestSurfaceRefresh()
            return
        }
        super.otherMouseDragged(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        _ = sendMousePosition(for: event)
        var horizontal = event.scrollingDeltaX
        var vertical = event.scrollingDeltaY
        let scrollMods = GhosttyEmbeddedTerminalView.makeScrollMods(
            hasPreciseDeltas: event.hasPreciseScrollingDeltas, momentumPhase: event.momentumPhase)
        if event.hasPreciseScrollingDeltas {
            horizontal *= 2
            vertical *= 2
        }
        guard sendScroll(horizontal: horizontal, vertical: vertical, mods: scrollMods) else {
            super.scrollWheel(with: event)
            return
        }
    }

    override func keyDown(with event: NSEvent) {
        guard acceptsTerminalInput else {
            super.keyDown(with: event)
            return
        }
        if GhosttyEmbeddedTerminalView.shouldDeferToSystemShortcut(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
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

        if let characters = GhosttyEmbeddedTerminalView.ghosttyText(for: event), !characters.isEmpty {
            onSendText?(characters)
            return
        }

        super.keyDown(with: event)
    }

    func update(snapshot: GhosttyTerminalSnapshot?, replayStateKey: String) {
        createSurfaceIfNeeded()
        if let lastReplayStateKey, lastReplayStateKey != replayStateKey {
            lastViewportSnapshot = nil
            lastReplayPixelSize = nil
        }
        lastSnapshot = snapshot
        lastReplayStateKey = replayStateKey
        guard surface != nil else { return }
        guard let snapshot else { return }
        let viewportSnapshot = viewportSnapshot(for: snapshot)
        let pixelSize = currentPixelSize()
        guard lastViewportSnapshot != viewportSnapshot || lastReplayPixelSize != pixelSize else { return }
        replay(snapshot: viewportSnapshot)
        lastViewportSnapshot = viewportSnapshot
        lastReplayPixelSize = pixelSize
    }

    func snapshot() -> GhosttyTerminalSnapshot? { GhosttyTerminalSnapshotCapture.captureFromSurface(surface) }

    func snapshotText() -> String? { lastRenderedText ?? GhosttyTerminalSnapshotCapture.captureText(from: surface) }

    func replayedText() -> String? { lastRenderedText }

    func copySelectionToPasteboard() -> Bool { GhosttyClipboardBridge.copySelection(from: surface) }

    func pasteClipboardContents() -> Bool {
        guard acceptsTerminalInput else { return false }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
        onSendText?(text)
        return true
    }

    @discardableResult func sendScroll(horizontal: CGFloat, vertical: CGFloat, mods: ghostty_input_scroll_mods_t = 0) -> Bool {
        guard let surface else { return false }
        focusWindow()
        ghostty_surface_mouse_scroll(surface, Double(horizontal), Double(vertical), mods)
        requestSurfaceRefresh()
        return true
    }

    func focusWindow(_ window: NSWindow?) {
        guard let window else { return }
        if window.firstResponder !== self { window.makeFirstResponder(self) }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        setSurfaceFocus(true)
    }

    func parkInHiddenHostWindowIfNeeded() {
        surfaceCreationRetryWorkItem?.cancel()
        surfaceCreationRetryWorkItem = nil
        destroySurface()
        removeFromSuperview()
    }

    private func installSurfaceHostView(_ hostView: GhosttyRemoteReplaySurfaceHostView) {
        hostView.translatesAutoresizingMaskIntoConstraints = false
        hostView.wantsLayer = true
        addSubview(hostView, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            hostView.topAnchor.constraint(equalTo: topAnchor), hostView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: trailingAnchor), hostView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeSurfaceHost(for hostView: GhosttyRemoteReplaySurfaceHostView) -> ghostty_surface_host_s {
        var host = ghostty_surface_host_s()
        host.platform_tag = GHOSTTY_PLATFORM_MACOS
        host.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(hostView).toOpaque()))
        host.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        return host
    }

    private func rebindSurfaceHostIfNeeded() {
        guard let window else { return }
        let windowNumber = window.windowNumber
        guard boundSurfaceWindowNumber != windowNumber else { return }

        let replacementHostView = GhosttyRemoteReplaySurfaceHostView(frame: .zero)
        installSurfaceHostView(replacementHostView)

        var replacementHost = makeSurfaceHost(for: replacementHostView)
        guard sessionDriver.updateRendererHost(renderer, host: &replacementHost) else {
            replacementHostView.removeFromSuperview()
            return
        }

        let previousHostView = surfaceHostView
        surfaceHostView = replacementHostView
        previousHostView.removeFromSuperview()
        boundSurfaceWindowNumber = windowNumber
        lastGeometry = nil
        lastFocused = nil
        lastOccluded = nil
        updateSurfaceGeometry()
        updateWindowVisibility()
        setSurfaceFocus(window.isKeyWindow && window.firstResponder === self)
        requestSurfaceRefresh()
    }

    private func createSurfaceIfNeeded() {
        guard window != nil else { return }
        if let nextSurfaceCreationRetryAt, Date() < nextSurfaceCreationRetryAt { return }

        guard backingPixelSize() != nil else {
            pendingSurfaceCreation = true
            scheduleSurfaceCreationRetry(after: 0.05)
            return
        }
        pendingSurfaceCreation = false

        do {
            try sessionDriver.startIfNeeded()
            if renderer == nil {
                var initialHost = makeSurfaceHost(for: surfaceHostView)
                renderer = ghostty_renderer_new(&initialHost)
            }
            guard renderer != nil, sessionDriver.attachRenderer(renderer) else {
                throw GhosttyEmbeddedAppServiceError.configuration("ghostty_renderer_attach failed")
            }

            boundSurfaceWindowNumber = window?.windowNumber
            surfaceCreationRetryWorkItem?.cancel()
            surfaceCreationRetryWorkItem = nil
            nextSurfaceCreationRetryAt = nil
            lastSurfaceCreationFailureMessage = nil
            lastGeometry = nil
            lastFocused = nil
            lastOccluded = nil
            updateSurfaceGeometry()
            updateWindowVisibility()
            setSurfaceFocus(window?.isKeyWindow == true && window?.firstResponder === self)
            replayLatestSnapshotIfNeeded()
            if let surface { ghostty_surface_refresh(surface) }
        } catch {
            pendingSurfaceCreation = true
            nextSurfaceCreationRetryAt = Date().addingTimeInterval(1)
            scheduleSurfaceCreationRetry(after: 1)
            let message = String(describing: error)
            if lastSurfaceCreationFailureMessage != message {
                lastSurfaceCreationFailureMessage = message
                fputs("spaces: ghostty remote replay surface creation failed: \(message)\n", stderr)
            }
        }
    }

    private func scheduleSurfaceCreationRetry(after delay: TimeInterval) {
        surfaceCreationRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.surfaceCreationRetryWorkItem = nil
                self.createSurfaceIfNeeded()
            }
        }
        surfaceCreationRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func destroySurface() {
        _ = sessionDriver.detachRenderer(renderer)
        boundSurfaceWindowNumber = nil
        lastGeometry = nil
        lastFocused = nil
        lastOccluded = nil
    }

    private func handleSurfaceClosed() {
        destroySurface()
        if let renderer {
            ghostty_renderer_free(renderer)
            self.renderer = nil
        }
    }

    private func replay(snapshot: GhosttyTerminalSnapshot) {
        let vt = GhosttyTerminalSnapshotVTEncoder.encode(snapshot)
        lastRenderedText = GhosttyTerminalSnapshotLayout.plainText(for: snapshot)
        sessionDriver.processOutput(vt)
        requestSurfaceRefresh()
    }

    private func viewportSnapshot(for snapshot: GhosttyTerminalSnapshot) -> GhosttyTerminalSnapshot {
        guard let surface else { return snapshot }
        let size = ghostty_surface_size(surface)
        let localColumns = Int(size.columns)
        let localRows = Int(size.rows)
        guard localColumns > 0, localRows > 0 else { return snapshot }
        return GhosttyTerminalSnapshotViewport.crop(snapshot, columns: localColumns, rows: localRows, horizontalAlignment: .leading)
    }

    private func replayLatestSnapshotIfNeeded() {
        guard let lastSnapshot else { return }
        guard surface != nil else { return }
        let pixelSize = currentPixelSize()
        guard lastReplayPixelSize != pixelSize else { return }
        let viewportSnapshot = viewportSnapshot(for: lastSnapshot)
        replay(snapshot: viewportSnapshot)
        lastViewportSnapshot = viewportSnapshot
        lastReplayPixelSize = pixelSize
    }

    private func updateSurfaceGeometry() {
        guard surface != nil, let window, let backingSize = backingPixelSize() else { return }
        let scale = Double(window.backingScaleFactor)
        let displayID = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let geometry = SurfaceGeometry(width: backingSize.width, height: backingSize.height, scale: scale, displayID: displayID)
        guard geometry != lastGeometry else { return }
        layer?.contentsScale = window.backingScaleFactor
        sessionDriver.updateGeometry(width: geometry.width, height: geometry.height, scale: scale, displayID: displayID)
        lastGeometry = geometry
    }

    private func updateWindowVisibility() {
        let visible = window?.occlusionState.contains(.visible) ?? true
        guard isWindowVisible != visible else { return }
        isWindowVisible = visible
        setSurfaceOcclusion(!visible)
    }

    private func backingPixelSize() -> (width: UInt32, height: UInt32)? {
        let directSize = convertToBacking(bounds).size
        if let measured = sanitizedPixelSize(directSize) { return measured }

        guard let window else { return nil }

        let contentLayoutSize = window.convertToBacking(window.contentLayoutRect).size
        if let measured = sanitizedPixelSize(contentLayoutSize) { return measured }

        if let contentView = window.contentView {
            let contentViewSize = contentView.convertToBacking(contentView.bounds).size
            if let measured = sanitizedPixelSize(contentViewSize) { return measured }
        }

        return nil
    }

    private func currentPixelSize() -> PixelSize? {
        guard let measured = backingPixelSize() else { return nil }
        return PixelSize(width: measured.width, height: measured.height)
    }

    private func sanitizedPixelSize(_ size: CGSize) -> (width: UInt32, height: UInt32)? {
        let width = Int(floor(size.width))
        let height = Int(floor(size.height))
        guard width > 0, height > 0 else { return nil }
        return (UInt32(width), UInt32(height))
    }

    private func focusWindow() {
        guard let window else { return }
        if window.firstResponder !== self { window.makeFirstResponder(self) }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        setSurfaceFocus(true)
    }

    private func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        case 57: .capsLock
        default: []
        }
    }

    private func ghosttyModifiers(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE
        if flags.contains(.shift) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SHIFT.rawValue) }
        if flags.contains(.control) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_CTRL.rawValue) }
        if flags.contains(.option) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_ALT.rawValue) }
        if flags.contains(.command) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SUPER.rawValue) }
        if flags.contains(.capsLock) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_CAPS.rawValue) }
        if flags.contains(.numericPad) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_NUM.rawValue) }
        return mods
    }

    private func sendMousePosition(for event: NSEvent) -> Bool {
        guard let surface else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let x = max(0, point.x)
        let y = max(0, GhosttyEmbeddedTerminalView.ghosttyMouseY(point.y, boundsHeight: bounds.height))
        ghostty_surface_mouse_pos(surface, Double(x), Double(y), ghosttyModifiers(from: event.modifierFlags))
        return true
    }

    private func sendMouseButton(event: NSEvent, state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, ghosttyModifiers(from: event.modifierFlags))
    }

    private func shouldRefreshSurfaceAfterMousePositionChange() -> Bool {
        if NSEvent.pressedMouseButtons != 0 { return true }
        guard let surface else { return false }
        return ghostty_surface_mouse_captured(surface)
    }

    private func mouseButton(for event: NSEvent) -> ghostty_input_mouse_button_e {
        switch event.buttonNumber {
        case 2: GHOSTTY_MOUSE_MIDDLE
        case 3: GHOSTTY_MOUSE_FOUR
        case 4: GHOSTTY_MOUSE_FIVE
        case 5: GHOSTTY_MOUSE_SIX
        case 6: GHOSTTY_MOUSE_SEVEN
        case 7: GHOSTTY_MOUSE_EIGHT
        case 8: GHOSTTY_MOUSE_NINE
        case 9: GHOSTTY_MOUSE_TEN
        case 10: GHOSTTY_MOUSE_ELEVEN
        default: GHOSTTY_MOUSE_UNKNOWN
        }
    }

    private func setSurfaceFocus(_ focused: Bool) {
        guard let surface else { return }
        guard lastFocused != focused else { return }
        lastFocused = focused
        ghostty_surface_set_focus(surface, focused)
    }

    private func setSurfaceOcclusion(_ occluded: Bool) {
        guard let surface else { return }
        guard lastOccluded != occluded else { return }
        lastOccluded = occluded
        ghostty_surface_set_occlusion(surface, occluded)
    }

    private func requestSurfaceRefresh() {
        GhosttyEmbeddedAppService.shared.tick()
        if let surface { ghostty_surface_refresh(surface) }
        surfaceHostView.needsDisplay = true
        surfaceHostView.layer?.setNeedsDisplay()
        needsDisplay = true
        layer?.setNeedsDisplay()
    }

    private func teardownWindowObservation() {
        NotificationCenter.default.removeObserver(self)
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        if let observedWindow, let previousAcceptsMouseMovedEvents { observedWindow.acceptsMouseMovedEvents = previousAcceptsMouseMovedEvents }
        previousAcceptsMouseMovedEvents = nil
        observedWindow = nil
    }

    @objc private func handleWindowDidChangeScreen(_ notification: Notification) { updateSurfaceGeometry() }
    @objc private func handleWindowDidChangeOcclusionState(_ notification: Notification) { updateWindowVisibility() }
    @objc private func handleWindowDidBecomeKey(_ notification: Notification) { setSurfaceFocus(true) }
    @objc private func handleWindowDidResignKey(_ notification: Notification) { setSurfaceFocus(false) }

    private static func replayLaunchConfiguration(from launchConfiguration: TerminalSessionLaunchConfiguration) -> TerminalSessionLaunchConfiguration
    {
        TerminalSessionLaunchConfiguration(
            sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, lifetimePolicy: launchConfiguration.lifetimePolicy,
            title: launchConfiguration.title, workingDirectory: launchConfiguration.workingDirectory, shell: "/bin/sh", command: carrierCommand,
            createdAt: launchConfiguration.createdAt)
    }

    private static func remoteKeySpecifier(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let fallback = GhosttyEmbeddedTerminalView.rawKeyFallbackSpecifier(for: event) { return fallback }
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "enter"
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
