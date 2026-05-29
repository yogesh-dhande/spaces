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

    private static let carrierCommand = "shell:stty -echo -icanon min 1 time 0; exec cat >/dev/null"
    private static let sessionResetSequence = Data("\u{1B}c".utf8)

    private let launchConfiguration: TerminalSessionLaunchConfiguration
    private let sessionDriver: GhosttyEmbeddedTerminalSessionDriver
    private var renderer: ghostty_renderer_t?
    private var pendingSurfaceCreation = false
    private var surfaceCreationRetryWorkItem: DispatchWorkItem?
    private var nextSurfaceCreationRetryAt: Date?
    private var lastSurfaceCreationFailureMessage: String?
    private var surfaceHostView = GhosttyRemoteReplaySurfaceHostView(frame: .zero)
    private var boundSurfaceWindowNumber: Int?
    private var isSurfaceAttached = false
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
    private var lastAppliedHistorySeedID: String?
    private var lastAppliedOutputEventToken: String?
    private var lastRenderedText: String?

    var acceptsTerminalInput = false
    var onSendText: SendTextHandler?
    var onSendKey: SendKeyHandler?
    var onViewportSizeChanged: ViewportSizeHandler?

    init(launchConfiguration: TerminalSessionLaunchConfiguration) {
        self.launchConfiguration = launchConfiguration
        sessionDriver = GhosttyEmbeddedTerminalSessionDriver(
            launchConfiguration: Self.replayLaunchConfiguration(from: launchConfiguration), allowsPTYFallback: false)
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

    var surface: ghostty_surface_t? { isSurfaceAttached ? sessionDriver.surface : nil }

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
        syncSurfaceFocusWithWindow()
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
        if accepted { syncSurfaceFocusWithWindow() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { setSurfaceFocus(false) }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        focusWindow()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) { super.mouseUp(with: event) }

    override func rightMouseDown(with event: NSEvent) {
        focusWindow()
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) { super.rightMouseUp(with: event) }

    override func otherMouseDown(with event: NSEvent) {
        focusWindow()
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) { super.otherMouseUp(with: event) }

    override func mouseMoved(with event: NSEvent) {
        if sendMousePosition(for: event) {
            if shouldRefreshSurfaceAfterMousePositionChange() { requestSurfaceRefresh() }
            return
        }
        super.mouseMoved(with: event)
    }

    override func mouseDragged(with event: NSEvent) { super.mouseDragged(with: event) }

    override func rightMouseDragged(with event: NSEvent) { super.rightMouseDragged(with: event) }

    override func otherMouseDragged(with event: NSEvent) { super.otherMouseDragged(with: event) }

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
        guard canProcessTerminalInput else {
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

    func update(
        snapshot: GhosttyTerminalSnapshot?, replayStateKey: String, historySeed: (id: String, data: Data)? = nil, outputData: Data?,
        outputEventToken: String?, forceHistorySeed: Bool = false
    ) {
        createSurfaceIfNeeded()
        let shouldApplyIncrementalOutput = canApplyIncrementalOutput(
            outputData: outputData, outputEventToken: outputEventToken, replayStateKey: replayStateKey)
        let shouldApplyHistorySeed =
            snapshot == nil && !shouldApplyIncrementalOutput
            && canApplyHistorySeed(historySeed, replayStateKey: replayStateKey, force: forceHistorySeed)
        if let lastReplayStateKey, lastReplayStateKey != replayStateKey, !shouldApplyIncrementalOutput, !shouldApplyHistorySeed {
            lastViewportSnapshot = nil
            lastReplayPixelSize = nil
            lastAppliedHistorySeedID = nil
            lastAppliedOutputEventToken = nil
        }
        lastSnapshot = snapshot
        lastReplayStateKey = replayStateKey
        guard surface != nil else { return }
        if shouldApplyHistorySeed, let historySeed {
            applyHistorySeed(historySeed)
            return
        }
        if !shouldApplyIncrementalOutput, let snapshot,
            canApplyIncrementalOutputAfterSnapshot(outputData: outputData, outputEventToken: outputEventToken)
        {
            replaySnapshotIfNeeded(snapshot)
            if let outputData { applyIncrementalOutput(outputData, outputEventToken: outputEventToken) }
            return
        }
        if shouldApplyIncrementalOutput, let outputData {
            applyIncrementalOutput(outputData, outputEventToken: outputEventToken)
            return
        }
        guard let snapshot else { return }
        replaySnapshotIfNeeded(snapshot)
    }

    @discardableResult private func replaySnapshotIfNeeded(_ snapshot: GhosttyTerminalSnapshot) -> Bool {
        let viewportSnapshot = viewportSnapshot(for: snapshot)
        let pixelSize = currentPixelSize()
        guard lastViewportSnapshot != viewportSnapshot || lastReplayPixelSize != pixelSize else { return false }
        replay(snapshot: viewportSnapshot)
        lastViewportSnapshot = viewportSnapshot
        lastReplayPixelSize = pixelSize
        return true
    }

    func snapshot() -> GhosttyTerminalSnapshot? { GhosttyTerminalSnapshotCapture.captureFromSurface(surface) }

    func snapshotText() -> String? { lastRenderedText ?? GhosttyTerminalSnapshotCapture.captureText(from: surface) }

    func replayedText() -> String? { lastRenderedText }

    var hasReplaySurfaceContent: Bool { lastViewportSnapshot != nil || lastAppliedHistorySeedID != nil || lastAppliedOutputEventToken != nil }

    func surfaceCellSize() -> (columns: Int, rows: Int)? {
        guard let surface else { return sessionDriver.surfaceCellSize() }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return sessionDriver.surfaceCellSize() }
        return (Int(size.columns), Int(size.rows))
    }

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
        syncSurfaceFocusWithWindow()
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

            isSurfaceAttached = true
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
            syncSurfaceFocusWithWindow()
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
        isSurfaceAttached = false
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

    private func resetSessionForFreshRender() {
        sessionDriver.processOutput(Self.sessionResetSequence)
        lastViewportSnapshot = nil
        lastReplayPixelSize = nil
        lastAppliedOutputEventToken = nil
        lastRenderedText = nil
    }

    private func canApplyHistorySeed(_ historySeed: (id: String, data: Data)?, replayStateKey: String, force: Bool = false) -> Bool {
        TerminalClientReplayCoordinator.shouldApplyHistorySeed(
            lastAppliedHistorySeedID: lastAppliedHistorySeedID, nextHistorySeedID: historySeed?.id,
            hasHistorySeedData: historySeed?.data.isEmpty == false, hasSurface: surface != nil,
            replayStateChanged: force || (lastReplayStateKey.map { $0 != replayStateKey } ?? true), hasReplaySurfaceContent: hasReplaySurfaceContent)
    }

    private func applyHistorySeed(_ historySeed: (id: String, data: Data)) {
        let renderData = TerminalReplayOutputSanitizer.renderableOutputData(from: historySeed.data)
        guard !renderData.isEmpty else {
            lastAppliedHistorySeedID = historySeed.id
            return
        }
        resetSessionForFreshRender()
        sessionDriver.processOutput(renderData)
        lastAppliedHistorySeedID = historySeed.id
        lastReplayPixelSize = currentPixelSize()
        requestSurfaceRefresh()
    }

    private func canApplyIncrementalOutput(outputData: Data?, outputEventToken: String?, replayStateKey: String) -> Bool {
        guard let outputData, !outputData.isEmpty else { return false }
        guard surface != nil else { return false }
        guard let outputEventToken, !outputEventToken.isEmpty else { return false }
        guard lastAppliedOutputEventToken != outputEventToken else { return false }
        guard lastReplayStateKey == replayStateKey else { return false }
        guard hasReplaySurfaceContent else { return false }
        return true
    }

    private func canApplyIncrementalOutputAfterSnapshot(outputData: Data?, outputEventToken: String?) -> Bool {
        guard let outputData, !outputData.isEmpty else { return false }
        guard surface != nil else { return false }
        guard let outputEventToken, !outputEventToken.isEmpty else { return false }
        guard lastAppliedOutputEventToken != outputEventToken else { return false }
        return true
    }

    private func applyIncrementalOutput(_ outputData: Data, outputEventToken: String?) {
        let renderData = TerminalReplayOutputSanitizer.renderableOutputData(from: outputData)
        guard !renderData.isEmpty else {
            lastAppliedOutputEventToken = outputEventToken
            return
        }
        sessionDriver.processOutput(renderData)
        lastSnapshot = nil
        lastRenderedText = nil
        lastAppliedOutputEventToken = outputEventToken
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
        guard lastAppliedHistorySeedID == nil else { return }
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

    private var canProcessTerminalInput: Bool { acceptsTerminalInput && window?.isKeyWindow == true && window?.firstResponder === self }

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

    private func shouldRefreshSurfaceAfterMousePositionChange() -> Bool {
        if NSEvent.pressedMouseButtons != 0 { return true }
        guard let surface else { return false }
        return ghostty_surface_mouse_captured(surface)
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
        if let surface { ghostty_surface_draw(surface) }
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
    @objc private func handleWindowDidBecomeKey(_ notification: Notification) { syncSurfaceFocusWithWindow() }
    @objc private func handleWindowDidResignKey(_ notification: Notification) { setSurfaceFocus(false) }

    private static func replayLaunchConfiguration(from launchConfiguration: TerminalSessionLaunchConfiguration) -> TerminalSessionLaunchConfiguration
    {
        TerminalSessionLaunchConfiguration(
            sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, lifetimePolicy: launchConfiguration.lifetimePolicy,
            title: launchConfiguration.title, workingDirectory: launchConfiguration.workingDirectory, shell: "/bin/sh", command: carrierCommand,
            createdAt: launchConfiguration.createdAt)
    }

    static func remoteKeySpecifier(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let semanticFlags = flags.subtracting([.function, .numericPad])
        if let fallback = GhosttyEmbeddedTerminalView.rawKeyFallbackSpecifier(for: event) { return fallback }
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

    private func syncSurfaceFocusWithWindow() { setSurfaceFocus(window?.isKeyWindow == true && window?.firstResponder === self) }

    private static func controlKeySpecifier(for event: NSEvent) -> String? {
        guard let flaglessCharacters = event.charactersIgnoringModifiers, flaglessCharacters.count == 1,
            let scalar = flaglessCharacters.unicodeScalars.first
        else { return nil }
        guard scalar.properties.isAlphabetic else { return nil }
        return "ctrl+\(String(scalar).lowercased())"
    }
}
