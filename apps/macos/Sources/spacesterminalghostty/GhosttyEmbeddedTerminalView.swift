import AppKit
import Foundation
import GhosttyKit
import spacesterminalcore

@MainActor public final class GhosttyEmbeddedTerminalView: NSView {
    public typealias SurfaceReadyHandler = @MainActor (ghostty_surface_t?) -> Void

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

    public init(launchConfiguration: TerminalSessionLaunchConfiguration) {
        self.launchConfiguration = launchConfiguration
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        screenChangeObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        occlusionObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        keyObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        resignKeyObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        if let surface { ghostty_surface_free(surface) }
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        screenChangeObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        screenChangeObserver = nil
        occlusionObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        occlusionObserver = nil
        keyObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        keyObserver = nil
        resignKeyObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        resignKeyObserver = nil

        guard let window else { return }
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

        updateSurfaceGeometry()
        setSurfaceFocus(window.isKeyWindow && window.firstResponder === self)
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
        guard let surface else {
            super.scrollWheel(with: event)
            return
        }
        _ = sendMousePosition(for: event)
        ghostty_surface_mouse_scroll(surface, Double(event.scrollingDeltaX), Double(event.scrollingDeltaY), 0)
    }

    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if sendGhosttyKey(event: event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS) { return }
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if let characters = event.characters, !characters.isEmpty { sendRawBytes(Data(characters.utf8)) }
    }

    public override func keyUp(with event: NSEvent) {
        if sendGhosttyKey(event: event, action: GHOSTTY_ACTION_RELEASE) { return }
        super.keyUp(with: event)
    }

    public override func flagsChanged(with event: NSEvent) {
        if sendGhosttyKey(event: event, action: modifierKeyAction(for: event)) { return }
        super.flagsChanged(with: event)
    }

    public func sendRawBytes(_ data: Data) {
        guard let surface, !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_surface_send_input_raw(surface, baseAddress, UInt(data.count))
        }
    }

    public func foregroundPID() -> Int32? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        guard pid > 0 else { return nil }
        return Int32(pid)
    }

    public func setOutputHandler(_ handler: (@Sendable (Data) -> Void)?) { outputHandler = handler }
    public func setFocused(_ focused: Bool) { setSurfaceFocus(focused) }

    func handleSurfaceClosed() { destroySurface() }

    private func createSurfaceIfNeeded() {
        guard surface == nil else { return }

        guard let backingSize = backingPixelSize() else {
            pendingSurfaceCreation = true
            return
        }
        pendingSurfaceCreation = false

        do {
            try GhosttyEmbeddedAppService.shared.startIfNeeded()
            guard let app = GhosttyEmbeddedAppService.shared.app else { throw GhosttyEmbeddedAppServiceError.configuration("ghostty app missing") }

            var surfaceConfig = ghostty_surface_config_new()
            surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
            surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
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
            GhosttyEmbeddedAppService.shared.registerActionHandler(for: createdSurface) { [weak self] event in
                guard let self else { return }
                self.onActionEvent?(event)
            }
            ghostty_surface_set_data_callback(createdSurface, Self.surfaceDataCallback, Unmanaged.passUnretained(self).toOpaque())
            updateSurfaceGeometry()
            ghostty_surface_set_size(createdSurface, backingSize.width, backingSize.height)
            setSurfaceFocus(window?.isKeyWindow == true && window?.firstResponder === self)
            ghostty_surface_refresh(createdSurface)
            onSurfaceReady?(createdSurface)
        } catch { fputs("spaces: ghostty surface creation failed: \(error)\n", stderr) }
    }

    private func destroySurface() {
        guard let surface else { return }
        onSurfaceReady?(nil)
        GhosttyEmbeddedAppService.shared.unregisterActionHandler(for: surface)
        ghostty_surface_set_data_callback(surface, nil, nil)
        ghostty_surface_free(surface)
        self.surface = nil
    }

    private func updateSurfaceGeometry() {
        guard let surface, let window, let backingSize = backingPixelSize() else { return }
        layer?.contentsScale = window.backingScaleFactor
        let scale = Double(window.backingScaleFactor)
        ghostty_surface_set_content_scale(surface, scale, scale)
        if let screen = window.screen, let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, displayID)
        }
        ghostty_surface_set_size(surface, backingSize.width, backingSize.height)
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
        window.makeFirstResponder(self)
        window.makeKeyAndOrderFront(nil)
        setSurfaceFocus(true)
    }

    private func sendGhosttyKey(event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }
        var input = ghostty_input_key_s()
        input.action = action
        input.mods = ghostty_surface_key_translation_mods(surface, ghosttyModifiers(from: event.modifierFlags))
        input.consumed_mods = GHOSTTY_MODS_NONE
        input.keycode = UInt32(event.keyCode)
        input.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first.map(\.value) ?? 0
        input.composing = false

        if let characters = event.characters, !characters.isEmpty {
            return characters.withCString { charactersPointer in
                input.text = charactersPointer
                return ghostty_surface_key(surface, input)
            }
        }

        input.text = nil
        return ghostty_surface_key(surface, input)
    }

    private func modifierKeyAction(for event: NSEvent) -> ghostty_input_action_e {
        let flag = modifierFlag(for: event.keyCode)
        if event.modifierFlags.contains(flag) { return GHOSTTY_ACTION_PRESS }
        return GHOSTTY_ACTION_RELEASE
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
        ghostty_surface_set_focus(surface, focused)
    }

    private func setSurfaceOcclusion(_ occluded: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, occluded)
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
}
