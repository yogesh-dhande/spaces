import AppKit
import Carbon
import Foundation
import GhosttyKit
import spacesterminalcore

@MainActor private final class GhosttyEmbeddedSurfaceHostView: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }

@MainActor public final class GhosttyEmbeddedTerminalView: NSView {
    public typealias SurfaceReadyHandler = @MainActor (ghostty_surface_t?) -> Void

    private struct SurfaceGeometry: Equatable {
        let width: UInt32
        let height: UInt32
        let scale: Double
        let displayID: UInt32?
    }

    public var onSurfaceReady: SurfaceReadyHandler?
    public var onActionEvent: (@MainActor (GhosttyActionEvent) -> Void)?
    public var onSessionClosed: (@MainActor () -> Void)?
    public var onSurfaceCellSizeChanged: (@MainActor (Int, Int) -> Void)?
    public var onInputActivity: (@MainActor () -> Void)?

    private let launchConfiguration: TerminalSessionLaunchConfiguration
    private let sessionDriver: GhosttyEmbeddedTerminalSessionDriver
    private var renderer: ghostty_renderer_t?
    private var desiredAttachmentMode: TerminalAttachmentMode = .owner
    private var pendingSurfaceCreation = false
    private nonisolated(unsafe) var screenChangeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var occlusionObserver: NSObjectProtocol?
    private nonisolated(unsafe) var keyObserver: NSObjectProtocol?
    private nonisolated(unsafe) var resignKeyObserver: NSObjectProtocol?
    private var isWindowVisible = true
    private var lastGeometry: SurfaceGeometry?
    private var lastFocused: Bool?
    private var lastOccluded: Bool?
    private var trackingArea: NSTrackingArea?
    private weak var observedWindow: NSWindow?
    private var previousAcceptsMouseMovedEvents: Bool?
    private var nextSurfaceCreationRetryAt: Date?
    private var lastSurfaceCreationFailureMessage: String?
    private var refreshScheduled = false
    private var surfaceCreationRetryWorkItem: DispatchWorkItem?
    private var surfaceHostView = GhosttyEmbeddedSurfaceHostView(frame: .zero)
    private var boundSurfaceWindowNumber: Int?
    private var isSurfaceAttached = false
    private var debugSurfaceRefreshRequestCountValue = 0
    private var debugSurfaceRefreshPerformedCountValue = 0

    private static let clearScreenBindingAction = "clear_screen"

    public var surface: ghostty_surface_t? { isSurfaceAttached ? sessionDriver.surface : nil }

    public convenience init(launchConfiguration: TerminalSessionLaunchConfiguration) {
        self.init(
            launchConfiguration: launchConfiguration, sessionDriver: GhosttyEmbeddedTerminalSessionDriver(launchConfiguration: launchConfiguration))
    }

    init(launchConfiguration: TerminalSessionLaunchConfiguration, sessionDriver: GhosttyEmbeddedTerminalSessionDriver) {
        self.launchConfiguration = launchConfiguration
        self.sessionDriver = sessionDriver
        super.init(frame: .zero)
        wantsLayer = true
        installSurfaceHostView(surfaceHostView)
        self.sessionDriver.onActionEvent = { [weak self] event in self?.onActionEvent?(event) }
        self.sessionDriver.onSurfaceCellSizeChanged = { [weak self] columns, rows in self?.onSurfaceCellSizeChanged?(columns, rows) }
        self.sessionDriver.onSurfaceClosed = { [weak self] in self?.handleSurfaceClosed() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        MainActor.assumeIsolated {
            teardownWindowObservation()
            surfaceCreationRetryWorkItem?.cancel()
            if let renderer { ghostty_renderer_free(renderer) }
        }
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        teardownWindowObservation()

        guard let window else { return }
        observedWindow = window
        createSurfaceIfNeeded()
        rebindSurfaceHostIfNeeded()

        screenChangeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.updateSurfaceGeometry() }
        }

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateWindowVisibility() } }

        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.syncSurfaceFocusWithWindow() }
        }
        resignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.setSurfaceFocus(false) }
        }

        if previousAcceptsMouseMovedEvents == nil { previousAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents }
        window.acceptsMouseMovedEvents = true

        updateSurfaceGeometry()
        updateWindowVisibility()
        syncSurfaceFocusWithWindow()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .enabledDuringMouseDrag]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if pendingSurfaceCreation { createSurfaceIfNeeded() }
        updateSurfaceGeometry()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceGeometry()
    }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { syncSurfaceFocusWithWindow() }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { setSurfaceFocus(false) }
        return accepted
    }

    public override func mouseDown(with event: NSEvent) {
        focusWindow()
        _ = sendMousePosition(for: event)
        _ = sendMouseButton(event: event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
        requestSurfaceRefresh()
    }

    public override func mouseUp(with event: NSEvent) {
        _ = sendMousePosition(for: event)
        _ = sendMouseButton(event: event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
        requestSurfaceRefresh()
    }

    public override func rightMouseDown(with event: NSEvent) {
        focusWindow()
        _ = sendMousePosition(for: event)
        if sendMouseButton(event: event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT) {
            requestSurfaceRefresh()
            return
        }
        super.rightMouseDown(with: event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        _ = sendMousePosition(for: event)
        if sendMouseButton(event: event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT) {
            requestSurfaceRefresh()
            return
        }
        super.rightMouseUp(with: event)
    }

    public override func otherMouseDown(with event: NSEvent) {
        focusWindow()
        _ = sendMousePosition(for: event)
        _ = sendMouseButton(event: event, state: GHOSTTY_MOUSE_PRESS, button: mouseButton(for: event))
        requestSurfaceRefresh()
    }

    public override func otherMouseUp(with event: NSEvent) {
        _ = sendMousePosition(for: event)
        _ = sendMouseButton(event: event, state: GHOSTTY_MOUSE_RELEASE, button: mouseButton(for: event))
        requestSurfaceRefresh()
    }

    public override func mouseMoved(with event: NSEvent) {
        if sendMousePosition(for: event) {
            if shouldRefreshSurfaceAfterMousePositionChange() { requestSurfaceRefresh() }
            return
        }
        super.mouseMoved(with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        if sendMousePosition(for: event) {
            requestSurfaceRefresh()
            return
        }
        super.mouseDragged(with: event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        if sendMousePosition(for: event) {
            requestSurfaceRefresh()
            return
        }
        super.rightMouseDragged(with: event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        if sendMousePosition(for: event) {
            requestSurfaceRefresh()
            return
        }
        super.otherMouseDragged(with: event)
    }

    public override func scrollWheel(with event: NSEvent) {
        _ = sendMousePosition(for: event)
        var horizontal = event.scrollingDeltaX
        var vertical = event.scrollingDeltaY
        let scrollMods = Self.makeScrollMods(hasPreciseDeltas: event.hasPreciseScrollingDeltas, momentumPhase: event.momentumPhase)
        if event.hasPreciseScrollingDeltas {
            // Match Ghostty's native macOS frontend, which applies a small
            // subjective boost to high-precision trackpad-style scroll input.
            horizontal *= 2
            vertical *= 2
        }
        guard sendScroll(horizontal: horizontal, vertical: vertical, mods: scrollMods) else {
            super.scrollWheel(with: event)
            return
        }
    }

    public override func keyDown(with event: NSEvent) {
        if Self.shouldDeferToSystemShortcut(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
            super.keyDown(with: event)
            return
        }
        guard canProcessTerminalInput else {
            super.keyDown(with: event)
            return
        }
        if event.type == .keyDown, Self.isClearScreenShortcut(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
            performClearScreenAction()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if sendGhosttyKey(event: event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS) {
            onInputActivity?()
            requestSurfaceRefresh()
            return
        }
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if let fallbackKey = Self.rawKeyFallbackSpecifier(for: event), let bytes = TerminalKeyInput.bytes(for: fallbackKey) {
            sendRawBytes(Data(bytes))
            return
        }
        if let characters = Self.ghosttyText(for: event), !characters.isEmpty { sendRawBytes(Data(characters.utf8)) }
    }

    public override func keyUp(with event: NSEvent) {
        guard canProcessTerminalInput else {
            super.keyUp(with: event)
            return
        }
        if sendGhosttyKey(event: event, action: GHOSTTY_ACTION_RELEASE) {
            requestSurfaceRefresh()
            return
        }
        super.keyUp(with: event)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard canProcessTerminalInput else {
            super.flagsChanged(with: event)
            return
        }
        if sendGhosttyKey(event: event, action: modifierKeyAction(for: event)) {
            requestSurfaceRefresh()
            return
        }
        super.flagsChanged(with: event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.shouldDeferToSystemShortcut(keyCode: event.keyCode, modifierFlags: event.modifierFlags) { return false }
        guard canProcessTerminalInput else { return false }
        if event.type == .keyDown, Self.isClearScreenShortcut(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
            performClearScreenAction()
            return true
        }
        guard event.type == .keyDown, let surface else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasActionModifier = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
        guard hasActionModifier else { return false }

        var input = makeGhosttyKeyEvent(for: event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        input.text = nil
        guard ghostty_surface_key_is_binding(surface, input, nil) else { return false }
        _ = ghostty_surface_key(surface, input)
        onInputActivity?()
        requestSurfaceRefresh()
        return true
    }

    @objc public func copy(_ sender: Any?) {
        guard GhosttyClipboardBridge.copySelection(from: surface) else {
            NSSound.beep()
            return
        }
    }

    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep()
            return
        }
        sendRawBytes(Data(text.utf8))
    }

    public func copySelectionToPasteboard() -> Bool { GhosttyClipboardBridge.copySelection(from: surface) }

    public func pasteClipboardContents() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
        sendRawBytes(Data(text.utf8))
        return true
    }

    public func sendRawBytes(_ data: Data) {
        guard !data.isEmpty else { return }
        sessionDriver.sendRawBytes(data)
        onInputActivity?()
    }

    public func foregroundPID() -> Int32? { sessionDriver.foregroundPID() }

    public func surfaceCellSize() -> (columns: Int, rows: Int)? {
        guard let surface else { return sessionDriver.surfaceCellSize() }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return sessionDriver.surfaceCellSize() }
        return (Int(size.columns), Int(size.rows))
    }

    public func sessionCellSize() -> (columns: Int, rows: Int)? { sessionDriver.surfaceCellSize() }

    @discardableResult public func resizeCellGrid(columns: Int, rows: Int) -> Bool { sessionDriver.resizeCellGrid(columns: columns, rows: rows) }

    public func setOutputHandler(_ handler: (@Sendable (Data) -> Void)?) { sessionDriver.setOutputHandler(handler) }
    public func setFocused(_ focused: Bool) { setSurfaceFocus(focused) }
    var isUsingFallbackPTY: Bool { sessionDriver.isUsingFallbackPTY }
    public func snapshot() -> GhosttyTerminalSnapshot? { GhosttyTerminalSnapshotCapture.captureFromSurface(surface) }
    public func snapshotText() -> String? { GhosttyTerminalSnapshotCapture.captureText(from: surface) }
    public func sessionSnapshot() -> GhosttyTerminalSnapshot? { sessionDriver.snapshot() }
    public func sessionSnapshotText() -> String? {
        guard let snapshot = sessionDriver.snapshot() else { return nil }
        return GhosttyTerminalSnapshotLayout.plainText(for: snapshot)
    }

    public func setAttachmentMode(_ mode: TerminalAttachmentMode) {
        guard desiredAttachmentMode != mode else { return }
        if desiredAttachmentMode == .owner, mode == .viewer { sessionDriver.preserveCurrentOwnerGeometryForParking() }
        desiredAttachmentMode = mode
        guard desiredAttachmentMode == .owner else {
            destroySurface()
            onSurfaceReady?(nil)
            return
        }
        createSurfaceIfNeeded()
    }

    private func installSurfaceHostView(_ hostView: GhosttyEmbeddedSurfaceHostView) {
        hostView.translatesAutoresizingMaskIntoConstraints = false
        hostView.wantsLayer = true
        addSubview(hostView, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            hostView.topAnchor.constraint(equalTo: topAnchor), hostView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: trailingAnchor), hostView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeSurfaceHost(for hostView: GhosttyEmbeddedSurfaceHostView) -> ghostty_surface_host_s {
        var host = ghostty_surface_host_s()
        host.platform_tag = GHOSTTY_PLATFORM_MACOS
        host.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(hostView).toOpaque()))
        host.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        return host
    }

    private func rebindSurfaceHostIfNeeded() {
        guard let window else { return }
        guard !sessionDriver.isUsingFallbackPTY else { return }
        let windowNumber = window.windowNumber
        guard boundSurfaceWindowNumber != windowNumber else { return }

        let replacementHostView = GhosttyEmbeddedSurfaceHostView(frame: .zero)
        installSurfaceHostView(replacementHostView)

        var replacementHost = makeSurfaceHost(for: replacementHostView)
        guard sessionDriver.updateRendererHost(renderer, host: &replacementHost) else {
            replacementHostView.removeFromSuperview()
            fputs("spaces: ghostty host rebind failed for session \(launchConfiguration.sessionID)\n", stderr)
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
        sessionDriver.requestSurfaceRefresh()
    }

    public func ensureHostingWindowForSurface() throws {
        if window == nil {
            if desiredAttachmentMode == .owner { try sessionDriver.startIfNeeded() }
            return
        }
        createSurfaceIfNeeded()
    }

    public func parkInHiddenHostWindowIfNeeded() {
        surfaceCreationRetryWorkItem?.cancel()
        surfaceCreationRetryWorkItem = nil
        destroySurface()
        removeFromSuperview()
        boundSurfaceWindowNumber = nil
        lastGeometry = nil
        lastFocused = nil
        lastOccluded = nil
    }

    public func requestSurfaceRefresh() {
        debugSurfaceRefreshRequestCountValue += 1
        guard surface != nil else {
            if desiredAttachmentMode == .owner { createSurfaceIfNeeded() }
            return
        }
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.performSurfaceRefresh() }
        }
    }

    public func terminateSession() {
        surfaceCreationRetryWorkItem?.cancel()
        surfaceCreationRetryWorkItem = nil
        destroySurface()
        sessionDriver.terminate()
        onSurfaceReady?(nil)
    }

    func handleSurfaceClosed() {
        destroySurface()
        onSurfaceReady?(nil)
        onSessionClosed?()
    }

    private func createSurfaceIfNeeded() {
        guard desiredAttachmentMode == .owner else { return }
        guard window != nil else { return }
        if let nextSurfaceCreationRetryAt, Date() < nextSurfaceCreationRetryAt { return }
        let startedAt = Date()

        guard let backingSize = backingPixelSize() else {
            pendingSurfaceCreation = true
            scheduleSurfaceCreationRetry(after: 0.05)
            return
        }
        pendingSurfaceCreation = false

        do {
            try sessionDriver.startIfNeeded()
            guard !sessionDriver.isUsingFallbackPTY else {
                isSurfaceAttached = false
                surfaceCreationRetryWorkItem?.cancel()
                surfaceCreationRetryWorkItem = nil
                nextSurfaceCreationRetryAt = nil
                lastSurfaceCreationFailureMessage = nil
                lastGeometry = nil
                lastFocused = nil
                lastOccluded = nil
                TerminalPerformance.logMetric(
                    "terminal_surface_create", target: "session=\(launchConfiguration.sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "fallback_pty=1")
                onSurfaceReady?(nil)
                return
            }
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
            if let surface { ghostty_surface_refresh(surface) }
            TerminalPerformance.logMetric(
                "terminal_surface_create", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
                detail: "width=\(backingSize.width) height=\(backingSize.height)")
            onSurfaceReady?(surface)
        } catch {
            TerminalPerformance.logMetric(
                "terminal_surface_create", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
            pendingSurfaceCreation = true
            nextSurfaceCreationRetryAt = Date().addingTimeInterval(1)
            scheduleSurfaceCreationRetry(after: 1)
            let message = String(describing: error)
            if lastSurfaceCreationFailureMessage != message {
                lastSurfaceCreationFailureMessage = message
                fputs("spaces: ghostty surface creation failed: \(message)\n", stderr)
            }
        }
    }

    @discardableResult func sendScroll(horizontal: CGFloat, vertical: CGFloat, mods: ghostty_input_scroll_mods_t = 0) -> Bool {
        guard let surface else { return false }
        focusWindow()
        ghostty_surface_mouse_scroll(surface, Double(horizontal), Double(vertical), mods)
        requestSurfaceRefresh()
        return true
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

        // Owner sessions can be attached before AppKit has pushed the final
        // layout into this view. Fall back to the live window content rect so
        // Ghostty can start immediately and then resize once layout settles.
        let contentLayoutSize = window.convertToBacking(window.contentLayoutRect).size
        if let measured = sanitizedPixelSize(contentLayoutSize) { return measured }

        if let contentView = window.contentView {
            let contentViewSize = contentView.convertToBacking(contentView.bounds).size
            if let measured = sanitizedPixelSize(contentViewSize) { return measured }
        }

        return nil
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

    private var canProcessTerminalInput: Bool {
        Self.canProcessTerminalInput(
            attachmentMode: desiredAttachmentMode, windowIsKey: window?.isKeyWindow == true, firstResponderIsSelf: window?.firstResponder === self,
            hasLiveInputBackend: surface != nil || sessionDriver.isUsingFallbackPTY)
    }

    @discardableResult private func performClearScreenAction() -> Bool {
        if let surface {
            let action = Self.clearScreenBindingAction
            let performed = action.withCString { actionPointer in ghostty_surface_binding_action(surface, actionPointer, UInt(action.utf8.count)) }
            if performed {
                onInputActivity?()
                requestSurfaceRefresh()
                return true
            }
        }

        sendRawBytes(Data(TerminalKeyInput.bytes(for: "ctrl+l") ?? [0x0C]))
        requestSurfaceRefresh()
        return true
    }

    private func sendGhosttyKey(event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }
        var input = makeGhosttyKeyEvent(for: event, action: action)

        if let characters = Self.ghosttyText(for: event), !characters.isEmpty {
            return characters.withCString { charactersPointer in
                input.text = charactersPointer
                return ghostty_surface_key(surface, input)
            }
        }

        input.text = nil
        return ghostty_surface_key(surface, input)
    }

    private func makeGhosttyKeyEvent(for event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var input = ghostty_input_key_s()
        input.action = action
        let translationModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        input.mods = ghostty_surface_key_translation_mods(surface, ghosttyModifiers(from: event.modifierFlags))
        input.consumed_mods = ghosttyModifiers(from: translationModifiers.subtracting([.control, .command]))
        input.keycode = UInt32(event.keyCode)
        input.unshifted_codepoint = Self.unshiftedCodepoint(for: event)
        input.composing = false
        input.text = nil
        return input
    }

    private func modifierKeyAction(for event: NSEvent) -> ghostty_input_action_e {
        let flag = modifierFlag(for: event.keyCode)
        if event.modifierFlags.contains(flag) { return GHOSTTY_ACTION_PRESS }
        return GHOSTTY_ACTION_RELEASE
    }

    static func shouldDeferToSystemShortcut(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let flags = modifierFlags.intersection([.command, .shift, .option, .control, .function])
        let isPlainCommandShortcut = flags == .command
        if isPlainCommandShortcut {
            switch Int(keyCode) {
            case kVK_ANSI_W, kVK_ANSI_M, kVK_ANSI_H, kVK_ANSI_Q, kVK_ANSI_Comma: return true
            default: break
            }
        }

        let isWindowTilingShortcut =
            flags == [.control, .function]
            && (keyCode == UInt16(kVK_LeftArrow) || keyCode == UInt16(kVK_RightArrow) || keyCode == UInt16(kVK_UpArrow)
                || keyCode == UInt16(kVK_DownArrow))
        return isWindowTilingShortcut
    }

    static func isClearScreenShortcut(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let flags = modifierFlags.intersection([.command, .shift, .option, .control, .function])
        return keyCode == UInt16(kVK_ANSI_K) && flags == .command
    }

    static func canProcessTerminalInput(
        attachmentMode: TerminalAttachmentMode, windowIsKey: Bool, firstResponderIsSelf: Bool, hasLiveInputBackend: Bool
    ) -> Bool { attachmentMode == .owner && windowIsKey && firstResponderIsSelf && hasLiveInputBackend }

    static func makeScrollMods(hasPreciseDeltas: Bool, momentumPhase: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var mods: Int32 = hasPreciseDeltas ? 0b0000_0001 : 0
        mods |= Int32(momentumRawValue(for: momentumPhase)) << 1
        return mods
    }

    static func momentumRawValue(for phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began: UInt8(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary: UInt8(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed: UInt8(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended: UInt8(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled: UInt8(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin: UInt8(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default: UInt8(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
    }

    static func ghosttyText(for event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        guard characters.count == 1, let scalar = characters.unicodeScalars.first else { return characters }

        if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }

        if isPrivateUseFunctionKeyScalar(scalar.value) { return nil }
        return characters
    }

    static func unshiftedCodepoint(for event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp, let characters = event.characters(byApplyingModifiers: []),
            let scalar = characters.unicodeScalars.first
        else { return 0 }
        return scalar.value
    }

    static func rawKeyFallbackSpecifier(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let navigationFlags = flags.subtracting([.numericPad, .function])
        let functionFlags = flags.subtracting(.function)
        switch Int(event.keyCode) {
        case kVK_UpArrow where navigationFlags.isEmpty: return "up"
        case kVK_DownArrow where navigationFlags.isEmpty: return "down"
        case kVK_LeftArrow where navigationFlags.isEmpty: return "left"
        case kVK_RightArrow where navigationFlags.isEmpty: return "right"
        case kVK_Home where navigationFlags.isEmpty: return "home"
        case kVK_End where navigationFlags.isEmpty: return "end"
        case kVK_PageUp where navigationFlags.isEmpty: return "pageup"
        case kVK_PageDown where navigationFlags.isEmpty: return "pagedown"
        case kVK_ForwardDelete where navigationFlags.isEmpty: return "forwarddelete"
        case kVK_Help where navigationFlags.isEmpty: return "insert"
        case kVK_Tab where flags == [.shift]: return "backtab"
        case kVK_F1 where functionFlags.isEmpty: return "f1"
        case kVK_F2 where functionFlags.isEmpty: return "f2"
        case kVK_F3 where functionFlags.isEmpty: return "f3"
        case kVK_F4 where functionFlags.isEmpty: return "f4"
        case kVK_F5 where functionFlags.isEmpty: return "f5"
        case kVK_F6 where functionFlags.isEmpty: return "f6"
        case kVK_F7 where functionFlags.isEmpty: return "f7"
        case kVK_F8 where functionFlags.isEmpty: return "f8"
        case kVK_F9 where functionFlags.isEmpty: return "f9"
        case kVK_F10 where functionFlags.isEmpty: return "f10"
        case kVK_F11 where functionFlags.isEmpty: return "f11"
        case kVK_F12 where functionFlags.isEmpty: return "f12"
        default: return nil
        }
    }

    static func isPrivateUseFunctionKeyScalar(_ value: UInt32) -> Bool { (0xF700...0xF8FF).contains(value) }

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
        let y = max(0, Self.ghosttyMouseY(point.y, boundsHeight: bounds.height))
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

    private func syncSurfaceFocusWithWindow() { setSurfaceFocus(window?.isKeyWindow == true && window?.firstResponder === self) }

    private func setSurfaceOcclusion(_ occluded: Bool) {
        guard let surface else { return }
        guard lastOccluded != occluded else { return }
        lastOccluded = occluded
        ghostty_surface_set_occlusion(surface, occluded)
    }

    private func performSurfaceRefresh() {
        let startedAt = Date()
        refreshScheduled = false
        guard surface != nil else { return }
        debugSurfaceRefreshPerformedCountValue += 1
        superview?.layoutSubtreeIfNeeded()
        surfaceHostView.layoutSubtreeIfNeeded()
        window?.contentView?.layoutSubtreeIfNeeded()
        GhosttyEmbeddedAppService.shared.tick()
        if let surface { ghostty_surface_draw(surface) }
        surfaceHostView.needsDisplay = true
        surfaceHostView.layer?.setNeedsDisplay()
        needsDisplay = true
        layer?.setNeedsDisplay()
        surfaceHostView.displayIfNeeded()
        displayIfNeeded()
        superview?.displayIfNeeded()
        window?.contentView?.displayIfNeeded()
        window?.displayIfNeeded()
        TerminalPerformance.logMetric(
            "terminal_surface_refresh", target: "session=\(launchConfiguration.sessionID)",
            elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
            detail: "requests=\(debugSurfaceRefreshRequestCountValue) performed=\(debugSurfaceRefreshPerformedCountValue)")
    }

    private func teardownWindowObservation() {
        screenChangeObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        screenChangeObserver = nil
        occlusionObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        occlusionObserver = nil
        keyObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        keyObserver = nil
        resignKeyObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        resignKeyObserver = nil
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        if let observedWindow, let previousAcceptsMouseMovedEvents { observedWindow.acceptsMouseMovedEvents = previousAcceptsMouseMovedEvents }
        previousAcceptsMouseMovedEvents = nil
        observedWindow = nil
    }

    nonisolated static func shouldDispatchSurfaceDataOutput(hasHandler: Bool, byteCount: Int) -> Bool { hasHandler && byteCount > 0 }

    static func ghosttyMouseY(_ localY: CGFloat, boundsHeight: CGFloat) -> CGFloat { boundsHeight - localY }

    var debugSurfaceRefreshRequestCount: Int { debugSurfaceRefreshRequestCountValue }
    var debugSurfaceRefreshPerformedCount: Int { debugSurfaceRefreshPerformedCountValue }
}
