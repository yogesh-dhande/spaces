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

    public nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    private let launchConfiguration: TerminalSessionLaunchConfiguration
    private var pendingSurfaceCreation = false
    private nonisolated(unsafe) var screenChangeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var occlusionObserver: NSObjectProtocol?
    private nonisolated(unsafe) var keyObserver: NSObjectProtocol?
    private nonisolated(unsafe) var resignKeyObserver: NSObjectProtocol?
    private var isWindowVisible = true
    private var outputHandler: (@Sendable (Data) -> Void)?
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
    private var hiddenHostWindow: NSWindow?
    private weak var hiddenHostContainerView: NSView?
    private let surfaceHostView = GhosttyEmbeddedSurfaceHostView(frame: .zero)
    private var debugSurfaceRefreshRequestCountValue = 0

    public init(launchConfiguration: TerminalSessionLaunchConfiguration) {
        self.launchConfiguration = launchConfiguration
        super.init(frame: .zero)
        wantsLayer = true
        surfaceHostView.translatesAutoresizingMaskIntoConstraints = false
        surfaceHostView.wantsLayer = true
        addSubview(surfaceHostView, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            surfaceHostView.topAnchor.constraint(equalTo: topAnchor), surfaceHostView.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceHostView.trailingAnchor.constraint(equalTo: trailingAnchor), surfaceHostView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        MainActor.assumeIsolated {
            teardownWindowObservation()
            surfaceCreationRetryWorkItem?.cancel()
        }
        if let surface { ghostty_surface_free(surface) }
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        teardownWindowObservation()

        guard let window else { return }
        observedWindow = window
        createSurfaceIfNeeded()

        screenChangeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.updateSurfaceGeometry() }
        }

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateWindowVisibility() } }

        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.setSurfaceFocus(true) }
        }
        resignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.setSurfaceFocus(false) }
        }

        if previousAcceptsMouseMovedEvents == nil { previousAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents }
        window.acceptsMouseMovedEvents = true

        updateSurfaceGeometry()
        updateWindowVisibility()
        setSurfaceFocus(window.isKeyWindow && window.firstResponder === self)
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
        if accepted { setSurfaceFocus(true) }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { setSurfaceFocus(false) }
        return accepted
    }

    public override func mouseDown(with event: NSEvent) {
        focusWindow()
        if sendMousePosition(for: event), sendMouseButton(event: event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT) { return }
        super.mouseDown(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if sendMousePosition(for: event), sendMouseButton(event: event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT) { return }
        super.mouseUp(with: event)
    }

    public override func rightMouseDown(with event: NSEvent) {
        focusWindow()
        if sendMousePosition(for: event), sendMouseButton(event: event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT) { return }
        super.rightMouseDown(with: event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        if sendMousePosition(for: event), sendMouseButton(event: event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT) { return }
        super.rightMouseUp(with: event)
    }

    public override func otherMouseDown(with event: NSEvent) {
        focusWindow()
        if sendMousePosition(for: event), sendMouseButton(event: event, state: GHOSTTY_MOUSE_PRESS, button: mouseButton(for: event)) { return }
        super.otherMouseDown(with: event)
    }

    public override func otherMouseUp(with event: NSEvent) {
        if sendMousePosition(for: event), sendMouseButton(event: event, state: GHOSTTY_MOUSE_RELEASE, button: mouseButton(for: event)) { return }
        super.otherMouseUp(with: event)
    }

    public override func mouseMoved(with event: NSEvent) {
        if sendMousePosition(for: event) { return }
        super.mouseMoved(with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        if sendMousePosition(for: event) { return }
        super.mouseDragged(with: event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        if sendMousePosition(for: event) { return }
        super.rightMouseDragged(with: event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        if sendMousePosition(for: event) { return }
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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if sendGhosttyKey(event: event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS) {
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
        if sendGhosttyKey(event: event, action: GHOSTTY_ACTION_RELEASE) {
            requestSurfaceRefresh()
            return
        }
        super.keyUp(with: event)
    }

    public override func flagsChanged(with event: NSEvent) {
        if sendGhosttyKey(event: event, action: modifierKeyAction(for: event)) {
            requestSurfaceRefresh()
            return
        }
        super.flagsChanged(with: event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.shouldDeferToSystemShortcut(keyCode: event.keyCode, modifierFlags: event.modifierFlags) { return false }
        guard event.type == .keyDown, let surface else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasActionModifier = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
        guard hasActionModifier else { return false }

        var input = makeGhosttyKeyEvent(for: event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        input.text = nil
        guard ghostty_surface_key_is_binding(surface, input, nil) else { return false }
        _ = ghostty_surface_key(surface, input)
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
        guard let surface, !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_surface_send_input_raw(surface, baseAddress, UInt(data.count))
        }
        requestSurfaceRefresh()
    }

    public func foregroundPID() -> Int32? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        guard pid > 0 else { return nil }
        return Int32(pid)
    }

    public func setOutputHandler(_ handler: (@Sendable (Data) -> Void)?) { outputHandler = handler }
    public func setFocused(_ focused: Bool) { setSurfaceFocus(focused) }
    public func snapshot() -> GhosttyTerminalSnapshot? { GhosttyTerminalSnapshotCapture.capture(from: surface) }

    public func ensureHostingWindowForSurface() {
        if window == nil { parkInHiddenHostWindowIfNeeded() }
        createSurfaceIfNeeded()
    }

    public func parkInHiddenHostWindowIfNeeded() {
        let hostWindow = ensureHiddenHostWindow()
        guard let hostContainerView = hiddenHostContainerView else { return }
        if superview !== hostContainerView {
            removeFromSuperview()
            frame = hostContainerView.bounds
            autoresizingMask = [.width, .height]
            hostContainerView.addSubview(self)
            hiddenHostWindow?.layoutIfNeeded()
        }
        if hostWindow.isVisible { hostWindow.orderOut(nil) }
    }

    public func requestSurfaceRefresh() {
        debugSurfaceRefreshRequestCountValue += 1
        guard surface != nil else {
            createSurfaceIfNeeded()
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
        if superview === hiddenHostContainerView { removeFromSuperview() }
        hiddenHostWindow?.orderOut(nil)
    }

    func handleSurfaceClosed() { destroySurface() }

    private func createSurfaceIfNeeded() {
        if window == nil { parkInHiddenHostWindowIfNeeded() }
        guard surface == nil else { return }
        if let nextSurfaceCreationRetryAt, Date() < nextSurfaceCreationRetryAt { return }
        let startedAt = Date()

        guard let backingSize = backingPixelSize() else {
            pendingSurfaceCreation = true
            scheduleSurfaceCreationRetry(after: 0.05)
            return
        }
        pendingSurfaceCreation = false

        do {
            try GhosttyEmbeddedAppService.shared.startIfNeeded()
            guard let app = GhosttyEmbeddedAppService.shared.app else { throw GhosttyEmbeddedAppServiceError.configuration("ghostty app missing") }

            var surfaceConfig = ghostty_surface_config_new()
            surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
            surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(surfaceHostView).toOpaque()))
            surfaceConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
            surfaceConfig.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
            surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

            var allocatedStrings: [UnsafeMutablePointer<CChar>] = []
            defer { for pointer in allocatedStrings { free(pointer) } }

            if let command = launchConfiguration.command,
                let wrapped = strdup(Self.loginShellCommand(shell: launchConfiguration.shell, command: command))
            {
                allocatedStrings.append(wrapped)
                surfaceConfig.command = UnsafePointer(wrapped)
                surfaceConfig.wait_after_command = false
            }

            let workingDirectory = launchConfiguration.workingDirectory
            let createdSurface = workingDirectory.withCString { cwd -> ghostty_surface_t? in
                surfaceConfig.working_directory = cwd
                return ghostty_surface_new(app, &surfaceConfig)
            }

            guard let createdSurface else { throw GhosttyEmbeddedAppServiceError.configuration("ghostty_surface_new failed") }

            surface = createdSurface
            surfaceCreationRetryWorkItem?.cancel()
            surfaceCreationRetryWorkItem = nil
            nextSurfaceCreationRetryAt = nil
            lastSurfaceCreationFailureMessage = nil
            lastGeometry = nil
            lastFocused = nil
            lastOccluded = nil
            GhosttyEmbeddedAppService.shared.registerActionHandler(for: createdSurface) { [weak self] event in
                guard let self else { return }
                self.onActionEvent?(event)
            }
            ghostty_surface_set_data_callback(createdSurface, Self.surfaceDataCallback, Unmanaged.passUnretained(self).toOpaque())
            updateSurfaceGeometry()
            updateWindowVisibility()
            setSurfaceFocus(window?.isKeyWindow == true && window?.firstResponder === self)
            ghostty_surface_refresh(createdSurface)
            GhosttyEmbeddedPerformance.logMetric(
                "terminal_surface_create", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: GhosttyEmbeddedPerformance.elapsedMS(since: startedAt), success: true,
                detail: "width=\(backingSize.width) height=\(backingSize.height)")
            onSurfaceReady?(createdSurface)
        } catch {
            GhosttyEmbeddedPerformance.logMetric(
                "terminal_surface_create", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: GhosttyEmbeddedPerformance.elapsedMS(since: startedAt), success: false)
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
        guard let surface else { return }
        onSurfaceReady?(nil)
        GhosttyEmbeddedAppService.shared.unregisterActionHandler(for: surface)
        ghostty_surface_set_data_callback(surface, nil, nil)
        ghostty_surface_free(surface)
        self.surface = nil
        lastGeometry = nil
        lastFocused = nil
        lastOccluded = nil
    }

    private func ensureHiddenHostWindow() -> NSWindow {
        if let hiddenHostWindow { return hiddenHostWindow }
        let frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        let hostWindow = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false
        hostWindow.alphaValue = 0
        hostWindow.ignoresMouseEvents = true
        hostWindow.backgroundColor = .clear
        let hostContainerView = NSView(frame: frame)
        hostContainerView.wantsLayer = true
        hostWindow.contentView = hostContainerView
        hostWindow.orderOut(nil)
        hiddenHostWindow = hostWindow
        hiddenHostContainerView = hostContainerView
        return hostWindow
    }

    private func updateSurfaceGeometry() {
        guard let surface, let window, let backingSize = backingPixelSize() else { return }
        let scale = Double(window.backingScaleFactor)
        let displayID = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let geometry = SurfaceGeometry(width: backingSize.width, height: backingSize.height, scale: scale, displayID: displayID)
        guard geometry != lastGeometry else { return }
        layer?.contentsScale = window.backingScaleFactor
        if lastGeometry?.scale != geometry.scale { ghostty_surface_set_content_scale(surface, scale, scale) }
        if lastGeometry?.displayID != geometry.displayID, let displayID { ghostty_surface_set_display_id(surface, displayID) }
        if lastGeometry?.width != geometry.width || lastGeometry?.height != geometry.height {
            ghostty_surface_set_size(surface, geometry.width, geometry.height)
        }
        lastGeometry = geometry
    }

    private func updateWindowVisibility() {
        let visible = window?.occlusionState.contains(.visible) ?? true
        guard isWindowVisible != visible else { return }
        isWindowVisible = visible
        setSurfaceOcclusion(!visible)
    }

    private func backingPixelSize() -> (width: UInt32, height: UInt32)? {
        let size = convertToBacking(bounds).size
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
        switch Int(event.keyCode) {
        case kVK_UpArrow where flags.isSubset(of: [.numericPad]): return "up"
        case kVK_DownArrow where flags.isSubset(of: [.numericPad]): return "down"
        case kVK_LeftArrow where flags.isSubset(of: [.numericPad]): return "left"
        case kVK_RightArrow where flags.isSubset(of: [.numericPad]): return "right"
        case kVK_Home where flags.isSubset(of: [.numericPad]): return "home"
        case kVK_End where flags.isSubset(of: [.numericPad]): return "end"
        case kVK_PageUp where flags.isSubset(of: [.numericPad]): return "pageup"
        case kVK_PageDown where flags.isSubset(of: [.numericPad]): return "pagedown"
        case kVK_ForwardDelete where flags.isSubset(of: [.numericPad]): return "forwarddelete"
        case kVK_Help where flags.isSubset(of: [.numericPad]): return "insert"
        case kVK_Tab where flags == [.shift]: return "backtab"
        case kVK_F1 where flags.isEmpty: return "f1"
        case kVK_F2 where flags.isEmpty: return "f2"
        case kVK_F3 where flags.isEmpty: return "f3"
        case kVK_F4 where flags.isEmpty: return "f4"
        case kVK_F5 where flags.isEmpty: return "f5"
        case kVK_F6 where flags.isEmpty: return "f6"
        case kVK_F7 where flags.isEmpty: return "f7"
        case kVK_F8 where flags.isEmpty: return "f8"
        case kVK_F9 where flags.isEmpty: return "f9"
        case kVK_F10 where flags.isEmpty: return "f10"
        case kVK_F11 where flags.isEmpty: return "f11"
        case kVK_F12 where flags.isEmpty: return "f12"
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
        let backingPoint = convertToBacking(point)
        let backingHeight = convertToBacking(bounds).height
        let x = max(0, backingPoint.x)
        let y = max(0, backingHeight - backingPoint.y)
        ghostty_surface_mouse_pos(surface, Double(x), Double(y), ghosttyModifiers(from: event.modifierFlags))
        return true
    }

    private func sendMouseButton(event: NSEvent, state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, ghosttyModifiers(from: event.modifierFlags))
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

    private func performSurfaceRefresh() {
        refreshScheduled = false
        guard let surface else { return }
        superview?.layoutSubtreeIfNeeded()
        surfaceHostView.layoutSubtreeIfNeeded()
        window?.contentView?.layoutSubtreeIfNeeded()
        GhosttyEmbeddedAppService.shared.tick()
        ghostty_surface_refresh(surface)
        surfaceHostView.needsDisplay = true
        surfaceHostView.layer?.setNeedsDisplay()
        needsDisplay = true
        layer?.setNeedsDisplay()
        surfaceHostView.displayIfNeeded()
        displayIfNeeded()
        superview?.displayIfNeeded()
        window?.contentView?.displayIfNeeded()
        window?.displayIfNeeded()
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

    private static func loginShellCommand(shell: String, command: String) -> String {
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        return "\(shell) -l -c '\(escaped)'"
    }

    private nonisolated(unsafe) static let surfaceDataCallback: ghostty_surface_data_cb = { userdata, bytes, len in
        guard let userdata, let bytes, len > 0 else { return }
        let view = Unmanaged<GhosttyEmbeddedTerminalView>.fromOpaque(userdata).takeUnretainedValue()
        let data = Data(bytes: bytes, count: Int(len))
        Task { @MainActor in view.outputHandler?(data) }
    }

    var debugSurfaceRefreshRequestCount: Int { debugSurfaceRefreshRequestCountValue }
}
