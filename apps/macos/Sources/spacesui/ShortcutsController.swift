import AppKit
import Carbon
import Foundation
import spacesclientcore
import spacesterminalcore
import systembridge
import workspacecore

/// Owns global-hotkey registration (Carbon `EventHotKeyRef`), the in-app local shortcut monitor,
/// shortcut-setting persistence, and the shortcut-capture settings UI. `AppKitController` holds a
/// single instance and delegates these to it.
///
/// The settings-card rows that host the capture buttons are built by the host (they live alongside
/// the rest of the settings panel), but the buttons target this controller directly; the host reaches
/// back into `shortcuts` for shortcut state (specs, capture buttons) and behavior (registration,
/// matching, display text) that other panes and controllers need.
@MainActor final class ShortcutsController: NSObject {
    unowned let host: AppKitController
    /// Opens the per-client desktop-state database shortcut settings are read from and persisted to.
    /// Injected rather than reaching through `host.clientDatabase()` so this controller owns its
    /// persistence dependency directly and a test can substitute a throwaway database.
    private let database: () throws -> SpacesClientDatabase

    init(host: AppKitController, database: @escaping () throws -> SpacesClientDatabase) {
        self.host = host
        self.database = database
        super.init()
    }

    private var hotkeyHandler: EventHandlerRef?
    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    var shortcutLeaderModifiers: Set<HotkeyModifier> = []
    private var pendingLeaderCaptureModifiers: Set<HotkeyModifier> = []
    private var toggleShortcutSpec: HotkeySpec?
    private var commandPaletteShortcutSpec: HotkeySpec?
    private var shortcutMonitor: Any?
    private var addWorkspaceShortcutSpec: HotkeySpec?
    private var reloadShortcutSpec: HotkeySpec?
    private var openEditorShortcutSpec: HotkeySpec?
    private var openTerminalShortcutSpec: HotkeySpec?
    // Not private: `AppKitController.handleNewTabSessionPickerShortcut` reads this from a different
    // file in the same module (cross-file `private` isn't visible).
    var newTabShortcutSpec: HotkeySpec?
    private var openFinderShortcutSpec: HotkeySpec?
    private var openSettingsShortcutSpec: HotkeySpec?
    private var nextShortcutSpec: HotkeySpec?
    private var previousShortcutSpec: HotkeySpec?
    private var sidebarNextShortcutSpec: HotkeySpec?
    private var sidebarPreviousShortcutSpec: HotkeySpec?
    // Not private: `AppKitController.windowShortcutIndex`/`windowShortcutBadgeText` read this from a
    // different file in the same module (cross-file `private` isn't visible).
    var windowShortcutSpec: HotkeySpec?
    var shortcutButtonsBySetting: [String: NSButton] = [:]
    var activeShortcutCaptureSetting: ShortcutSetting?

    private lazy var hotkeyHandlerProc: EventHandlerUPP = { _, event, userData in
        guard let userData else { return noErr }
        let controller = Unmanaged<ShortcutsController>.fromOpaque(userData).takeUnretainedValue()
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        if status != noErr { return status }
        controller.host.logHotkeyDebug(
            "event_received id=\(hotKeyID.id) status=\(status) main_thread=\(Thread.isMainThread ? 1 : 0) \(controller.host.hotkeyWindowStateSummary())")
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                controller.host.logHotkeyDebug("event_dispatch_direct id=\(hotKeyID.id)")
                controller.handleGlobalHotkey(id: hotKeyID.id)
            }
        } else {
            Task { @MainActor in
                controller.host.logHotkeyDebug("event_dispatch_task id=\(hotKeyID.id)")
                controller.handleGlobalHotkey(id: hotKeyID.id)
            }
        }
        return noErr
    }

    func setupGlobalHotkey() {
        guard host.desktopControlLease != nil else {
            host.logHotkeyDebug("setup skipped no_desktop_control_lease")
            teardownGlobalHotkey()
            return
        }
        guard let toggleShortcutSpec else {
            host.logHotkeyDebug("setup skipped missing_toggle_spec")
            teardownGlobalHotkey()
            return
        }
        host.logHotkeyDebug(
            "setup start toggle=\(toggleShortcutSpec) palette=\(String(describing: commandPaletteShortcutSpec)) next=\(String(describing: nextShortcutSpec)) previous=\(String(describing: previousShortcutSpec))"
        )
        registerHotkeys(
            toggle: toggleShortcutSpec, commandPalette: commandPaletteShortcutSpec, next: nextShortcutSpec, previous: previousShortcutSpec)
    }

    func teardownGlobalHotkey() {
        host.logHotkeyDebug("teardown refs=\(hotkeyRefs.count) handler=\(hotkeyHandler == nil ? 0 : 1)")
        for ref in hotkeyRefs.values { UnregisterEventHotKey(ref) }
        hotkeyRefs.removeAll()
        if let hotkeyHandler { RemoveEventHandler(hotkeyHandler) }
        hotkeyHandler = nil
    }

    private func registerHotkeys(toggle: HotkeySpec, commandPalette: HotkeySpec?, next: HotkeySpec?, previous: HotkeySpec?) {
        teardownGlobalHotkey()
        let signature = OSType(UInt32(truncatingIfNeeded: "AMUX".utf8.reduce(0) { ($0 << 8) + UInt32($1) }))
        let target = GetEventDispatcherTarget()
        host.logHotkeyDebug("register begin signature=\(signature)")
        registerHotkey(spec: toggle, id: GlobalHotkey.toggle.rawValue, signature: signature, target: target)
        if let commandPalette {
            registerHotkey(spec: commandPalette, id: GlobalHotkey.openCommandPalette.rawValue, signature: signature, target: target)
        }
        if let next { registerHotkey(spec: next, id: GlobalHotkey.next.rawValue, signature: signature, target: target) }
        if let previous { registerHotkey(spec: previous, id: GlobalHotkey.previous.rawValue, signature: signature, target: target) }
        if let openEditorShortcutSpec {
            registerHotkey(spec: openEditorShortcutSpec, id: GlobalHotkey.openEditor.rawValue, signature: signature, target: target)
        }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            target, hotkeyHandlerProc, 1, &eventSpec, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &hotkeyHandler)
        host.logHotkeyDebug("register handler_status=\(status) refs=\(hotkeyRefs.count) handler=\(hotkeyHandler == nil ? 0 : 1)")
    }

    private func registerHotkey(spec: HotkeySpec, id: UInt32, signature: OSType, target: EventTargetRef?) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(UInt32(spec.keyCode), spec.modifiersCarbon, hotKeyID, target, 0, &ref)
        host.logHotkeyDebug("register_hotkey id=\(id) spec=\(spec) status=\(status) ref=\(ref == nil ? 0 : 1)")
        if status == noErr, let ref { hotkeyRefs[id] = ref }
    }

    func setupShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged { return self.handleLeaderShortcutCaptureFlagsChanged(event: event) ? nil : event }
            // A focused terminal pane owns ordinary terminal input; app shortcut
            // chords run first so leader-backed shortcuts still work inside panes.
            let focusedPaneContent = self.host.panelCoordinator.contentOwning(responder: NSApp.keyWindow?.firstResponder)
            var focusedTerminalDisposition: ShortcutMonitorDisposition?
            if let focusedPaneContent {
                self.host.panelCoordinator.noteContentFocused(focusedPaneContent)
                let disposition = Self.shortcutMonitorDisposition(
                    eventModifiers: event.modifierFlags, firstResponderIsTerminalPane: focusedPaneContent is any TerminalPaneContentHosting,
                    shortcutLeaderModifiers: self.shortcutLeaderModifiers)
                focusedTerminalDisposition = disposition
                if disposition == .passEventToTerminal { return focusedPaneContent.handleKeyEvent(event) ? nil : event }
            }
            self.host.recordStartupInteraction(kind: "key_down")
            if self.handleShortcutCaptureEvent(event: event) { return nil }
            if self.handleNewWorkspaceShortcut(event: event) { return nil }
            if self.handleReloadShortcut(event: event) { return nil }
            if self.host.projectForms.handleFormCancelShortcut(event: event) { return nil }
            if self.host.alerts.handleAlertsShortcut(event: event) { return nil }
            if let openSettingsShortcutSpec, self.matches(event: event, spec: openSettingsShortcutSpec) {
                self.host.showSettings()
                return nil
            }
            if self.host.commandPalette.handleCommandPaletteShortcut(event: event) { return nil }
            if self.host.handleNewTabSessionPickerShortcut(event: event) { return nil }
            if self.host.handleClosePaneShortcut(event: event) { return nil }
            if self.host.handleFocusedTextInputShortcut(event: event) { return nil }
            if self.host.isTextInputFocused() { return event }
            if self.handleSidebarNavigationShortcut(event: event) { return nil }
            if let openTerminalShortcutSpec, self.matches(event: event, spec: openTerminalShortcutSpec) {
                // Global panel windows carry no tabs (and so no "new tab" of their own): this
                // always lands in the selected workspace's panel, even when a panel window is key.
                if let workspaceID = self.host.selectedWorkspaceID { self.host.openWorkspaceTerminal(workspaceID: workspaceID, route: .shortcut) }
                return nil
            }
            if let openFinderShortcutSpec, self.matches(event: event, spec: openFinderShortcutSpec) {
                // Unlike the editor path, this one needs no palette dismissal of its own. The editor
                // runs off a Carbon global hotkey that fires with any app frontmost, so it can be
                // invoked while the palette is key; this is a local monitor, and a visible palette is
                // key with its search field first responder, so the `isTextInputFocused()` check above
                // returns the event before reaching here. Finder therefore cannot be covered by the
                // palette's return-focus restore.
                if let workspaceID = self.host.selectedWorkspaceID { self.host.openWorkspaceFinder(workspaceID: workspaceID) }
                return nil
            }
            if let windowIndex = self.host.windowShortcutIndex(for: event) {
                self.host.logWindowShortcutProfile("stage=monitor_schedule index=\(windowIndex)")
                let startedAt = Date()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.host.logWindowShortcutProfile("stage=monitor_dispatch index=\(windowIndex)")
                    await self.host.runWindowShortcut(index: windowIndex, startedAt: startedAt)
                    self.host.logWindowShortcutProfile("stage=monitor_after_handler index=\(windowIndex)")
                }
                return nil
            }
            // App shortcuts did not claim the chord. Command shortcuts fall through
            // to terminal command-equivalent handling; non-Command leader chords
            // fall through to the pane's normal key handling, including image paste.
            if let focusedPaneContent, focusedPaneContent.handleCommandKeyEquivalent(event) { return nil }
            if focusedTerminalDisposition == .runAppShortcutsThenTerminal, let focusedPaneContent {
                return focusedPaneContent.handleKeyEvent(event) ? nil : event
            }
            return event
        }
    }

    func teardownShortcutMonitor() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
    }

    private func handleGlobalHotkey(id: UInt32) {
        guard let hotkey = GlobalHotkey(rawValue: id) else { return }
        host.logHotkeyDebug("handle id=\(id) hotkey=\(hotkey) \(host.hotkeyWindowStateSummary())")
        switch hotkey {
        case .toggle: host.toggleWindowFromHotkey()
        case .openCommandPalette: host.commandPalette.toggleCommandPaletteFromHotkey()
        case .next: host.focusGlobalWindowNavigation(direction: 1)
        case .previous: host.focusGlobalWindowNavigation(direction: -1)
        case .openEditor: host.openGlobalEditorFromHotkey()
        }
    }

    private func handleLeaderShortcutCaptureFlagsChanged(event: NSEvent) -> Bool {
        guard activeShortcutCaptureSetting == .guiLeaderHotkey else { return false }
        let modifiers = currentPressedShortcutModifiers(fallback: event.modifierFlags)
        if !modifiers.isEmpty {
            pendingLeaderCaptureModifiers.formUnion(modifiers)
            refreshShortcutCaptureButtons()
            return true
        }
        guard !pendingLeaderCaptureModifiers.isEmpty else { return true }
        do {
            try setShortcutSetting(setting: .guiLeaderHotkey, value: HotkeySpec.normalizedModifierSet(pendingLeaderCaptureModifiers))
            pendingLeaderCaptureModifiers = []
            activeShortcutCaptureSetting = nil
            loadShortcutSpecs()
            setupGlobalHotkey()
            host.refreshSelection()
        } catch {
            pendingLeaderCaptureModifiers = []
            activeShortcutCaptureSetting = nil
            refreshShortcutCaptureButtons()
            host.showError(error)
        }
        return true
    }

    private func handleNewWorkspaceShortcut(event: NSEvent) -> Bool {
        guard let addWorkspaceShortcutSpec, matches(event: event, spec: addWorkspaceShortcutSpec) else { return false }
        if host.showingAlerts, host.windowShortcutIndex(for: event) != nil { return false }
        if host.projectForms.activeAddWorkspaceFormTag != nil { return true }
        host.projectForms.addWorkspaceFromShortcut()
        return true
    }

    private func handleReloadShortcut(event: NSEvent) -> Bool {
        guard let reloadShortcutSpec, matches(event: event, spec: reloadShortcutSpec) else { return false }
        host.reloadData(forceRemoteRefresh: true)
        return true
    }

    private func handleShortcutCaptureEvent(event: NSEvent) -> Bool {
        guard let setting = activeShortcutCaptureSetting else { return false }
        if event.keyCode == UInt16(kVK_Escape) {
            pendingLeaderCaptureModifiers = []
            activeShortcutCaptureSetting = nil
            refreshShortcutCaptureButtons()
            return true
        }
        guard let spec = shortcutCaptureSpec(from: event) else {
            NSSound.beep()
            return true
        }
        guard setting.capturesModifierOnly || !spec.modifiers.isEmpty else {
            NSSound.beep()
            return true
        }
        guard shortcutCaptureAccepts(spec: spec, setting: setting) else {
            NSSound.beep()
            return true
        }

        do {
            try setShortcutSetting(setting: setting, value: normalizedShortcutSettingValue(spec: spec, setting: setting))
            pendingLeaderCaptureModifiers = []
            activeShortcutCaptureSetting = nil
            loadShortcutSpecs()
            setupGlobalHotkey()
            host.refreshSelection()
        } catch {
            pendingLeaderCaptureModifiers = []
            activeShortcutCaptureSetting = nil
            refreshShortcutCaptureButtons()
            host.showError(error)
        }
        return true
    }

    private func shortcutCaptureSpec(from event: NSEvent) -> HotkeySpec? {
        guard let key = shortcutCaptureKey(for: event.keyCode) else { return nil }
        return HotkeySpec(key: key, modifiers: shortcutModifiers(from: event.modifierFlags))
    }

    private func shortcutCaptureAccepts(spec: HotkeySpec, setting: ShortcutSetting) -> Bool {
        if setting.usesDigitRangeCapture { return Int(spec.key) != nil }
        return true
    }

    private func normalizedShortcutSettingValue(spec: HotkeySpec, setting: ShortcutSetting) -> String {
        if setting.usesLeader {
            let suffixModifiers =
                spec.modifiers.isSuperset(of: shortcutLeaderModifiers) ? spec.modifiers.subtracting(shortcutLeaderModifiers) : spec.modifiers
            let suffixKey = setting.usesDigitRangeCapture ? "1" : spec.key
            return HotkeySpec(key: suffixKey, modifiers: suffixModifiers).normalized
        }
        if setting.usesDigitRangeCapture { return HotkeySpec(key: "1", modifiers: spec.modifiers).normalized }
        return spec.normalized
    }

    private func shortcutCaptureKey(for keyCode: UInt16) -> String? { ShortcutsController.shortcutCaptureKeyMap[keyCode] }

    func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> { Self.eventShortcutModifiers(from: flags) }

    nonisolated static func eventShortcutModifiers(from flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> {
        let filtered = flags.intersection([.command, .shift, .option, .control])
        var modifiers = Set<HotkeyModifier>()
        if filtered.contains(.command) { modifiers.insert(.cmd) }
        if filtered.contains(.shift) { modifiers.insert(.shift) }
        if filtered.contains(.option) { modifiers.insert(.alt) }
        if filtered.contains(.control) { modifiers.insert(.ctrl) }
        return modifiers
    }

    private func currentPressedShortcutModifiers(fallback flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> {
        let pressedModifierKeys: [(HotkeyModifier, [CGKeyCode])] = [
            (.cmd, [CGKeyCode(kVK_Command), CGKeyCode(kVK_RightCommand)]), (.shift, [CGKeyCode(kVK_Shift), CGKeyCode(kVK_RightShift)]),
            (.alt, [CGKeyCode(kVK_Option), CGKeyCode(kVK_RightOption)]), (.ctrl, [CGKeyCode(kVK_Control), CGKeyCode(kVK_RightControl)]),
        ]

        var modifiers = Set<HotkeyModifier>()
        for (modifier, keyCodes) in pressedModifierKeys {
            if keyCodes.contains(where: { CGEventSource.keyState(.combinedSessionState, key: $0) }) { modifiers.insert(modifier) }
        }
        return modifiers.isEmpty ? shortcutModifiers(from: flags) : modifiers
    }

    private static let shortcutCaptureKeyMap: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "a", UInt16(kVK_ANSI_B): "b", UInt16(kVK_ANSI_C): "c", UInt16(kVK_ANSI_D): "d", UInt16(kVK_ANSI_E): "e",
        UInt16(kVK_ANSI_F): "f", UInt16(kVK_ANSI_G): "g", UInt16(kVK_ANSI_H): "h", UInt16(kVK_ANSI_I): "i", UInt16(kVK_ANSI_J): "j",
        UInt16(kVK_ANSI_K): "k", UInt16(kVK_ANSI_L): "l", UInt16(kVK_ANSI_M): "m", UInt16(kVK_ANSI_N): "n", UInt16(kVK_ANSI_O): "o",
        UInt16(kVK_ANSI_P): "p", UInt16(kVK_ANSI_Q): "q", UInt16(kVK_ANSI_R): "r", UInt16(kVK_ANSI_S): "s", UInt16(kVK_ANSI_T): "t",
        UInt16(kVK_ANSI_U): "u", UInt16(kVK_ANSI_V): "v", UInt16(kVK_ANSI_W): "w", UInt16(kVK_ANSI_X): "x", UInt16(kVK_ANSI_Y): "y",
        UInt16(kVK_ANSI_Z): "z", UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2", UInt16(kVK_ANSI_3): "3",
        UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5", UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9", UInt16(kVK_ANSI_Equal): "=", UInt16(kVK_ANSI_Minus): "minus", UInt16(kVK_ANSI_LeftBracket): "[",
        UInt16(kVK_ANSI_RightBracket): "]", UInt16(kVK_ANSI_Semicolon): ";", UInt16(kVK_ANSI_Quote): "'", UInt16(kVK_ANSI_Comma): ",",
        UInt16(kVK_ANSI_Period): ".", UInt16(kVK_ANSI_Slash): "/", UInt16(kVK_ANSI_Backslash): "\\", UInt16(kVK_ANSI_Grave): "`",
        UInt16(kVK_Space): "space", UInt16(kVK_Tab): "tab", UInt16(kVK_Return): "return", UInt16(kVK_Escape): "escape", UInt16(kVK_Delete): "delete",
        UInt16(kVK_ForwardDelete): "forwarddelete", UInt16(kVK_LeftArrow): "left", UInt16(kVK_RightArrow): "right", UInt16(kVK_UpArrow): "up",
        UInt16(kVK_DownArrow): "down", UInt16(kVK_F1): "f1", UInt16(kVK_F2): "f2", UInt16(kVK_F3): "f3", UInt16(kVK_F4): "f4", UInt16(kVK_F5): "f5",
        UInt16(kVK_F6): "f6", UInt16(kVK_F7): "f7", UInt16(kVK_F8): "f8", UInt16(kVK_F9): "f9", UInt16(kVK_F10): "f10", UInt16(kVK_F11): "f11",
        UInt16(kVK_F12): "f12", UInt16(kVK_F13): "f13", UInt16(kVK_F14): "f14", UInt16(kVK_F15): "f15", UInt16(kVK_F16): "f16",
        UInt16(kVK_F17): "f17", UInt16(kVK_F18): "f18", UInt16(kVK_F19): "f19", UInt16(kVK_F20): "f20",
    ]

    /// Leader+↑/↓ moves the sidebar selection (Alerts and workspaces) from anywhere
    /// in the main window — including while a terminal pane owns the plain arrow
    /// keys. A matched chord is always consumed, so hitting a list edge doesn't leak
    /// the keystroke into the terminal.
    private func handleSidebarNavigationShortcut(event: NSEvent) -> Bool {
        if let sidebarPreviousShortcutSpec, matches(event: event, spec: sidebarPreviousShortcutSpec) {
            _ = host.sidebar.navigateSidebarSelection(direction: -1)
            return true
        }
        if let sidebarNextShortcutSpec, matches(event: event, spec: sidebarNextShortcutSpec) {
            _ = host.sidebar.navigateSidebarSelection(direction: 1)
            return true
        }
        return false
    }

    enum ShortcutMonitorDisposition: Equatable, Sendable {
        /// Send the event directly to the focused terminal pane before the shortcut
        /// chain handles it.
        case passEventToTerminal
        /// Run the app-shortcut chain; unhandled events still fall through to the
        /// window, whose key routing forwards them to the focused pane.
        case runAppShortcuts
        /// Run the app-shortcut chain first, then send an unclaimed event directly
        /// to the focused terminal pane.
        case runAppShortcutsThenTerminal
    }

    /// Keyboard routing for the local shortcut monitor once terminals live inside app
    /// windows as panes: a focused terminal owns ordinary input, while ⌘ chords and
    /// configured leader chords run app shortcuts first. With no terminal focused,
    /// all shortcuts run as before.
    nonisolated static func shortcutMonitorDisposition(
        eventModifiers: NSEvent.ModifierFlags, firstResponderIsTerminalPane: Bool, shortcutLeaderModifiers: Set<HotkeyModifier> = []
    ) -> ShortcutMonitorDisposition {
        guard firstResponderIsTerminalPane else { return .runAppShortcuts }
        let modifiers = eventShortcutModifiers(from: eventModifiers)
        if modifiers.contains(.cmd) { return .runAppShortcuts }
        if !shortcutLeaderModifiers.isEmpty, modifiers.isSuperset(of: shortcutLeaderModifiers) { return .runAppShortcutsThenTerminal }
        return .passEventToTerminal
    }

    // Reads every shortcut setting (up to twice each for leader-backed ones) against a single
    // resolver built once for the whole pass, instead of resolving the client database fresh per
    // setting: `shortcutSettingResolver()` resolves it once and every `value(key)` call below reuses
    // that same handle.
    func loadShortcutSpecs() {
        let resolver = shortcutSettingResolver()
        if let modifiers = try? resolver.leaderModifiers() {
            shortcutLeaderModifiers = modifiers
        } else if shortcutLeaderModifiers.isEmpty {
            // A read that throws keeps the leader already in effect (see `resolvedShortcutSpec`); the
            // default answers only a load that has never succeeded, and never an empty set, which would
            // leave every leader-backed chord matching a bare letter.
            shortcutLeaderModifiers = (try? HotkeySpec.parseModifierSet(ClientSettingsKey.defaultGUILeaderHotkey)) ?? [.cmd, .alt]
        }
        toggleShortcutSpec = loadShortcutSpec(resolver, setting: .guiHotkey)
        commandPaletteShortcutSpec = loadShortcutSpec(resolver, setting: .guiCommandPaletteHotkey)
        host.alerts.alertsShortcutSpec = loadShortcutSpec(resolver, setting: .guiAlertsShortcut)
        addWorkspaceShortcutSpec = loadShortcutSpec(resolver, setting: .guiAddWorkspaceShortcut)
        reloadShortcutSpec = loadShortcutSpec(resolver, setting: .guiReloadShortcut)
        nextShortcutSpec = loadShortcutSpec(resolver, setting: .guiNextShortcut)
        previousShortcutSpec = loadShortcutSpec(resolver, setting: .guiPreviousShortcut)
        sidebarNextShortcutSpec = loadShortcutSpec(resolver, setting: .guiSidebarNextShortcut)
        sidebarPreviousShortcutSpec = loadShortcutSpec(resolver, setting: .guiSidebarPreviousShortcut)
        openEditorShortcutSpec = loadShortcutSpec(resolver, setting: .guiOpenEditorShortcut)
        openTerminalShortcutSpec = loadShortcutSpec(resolver, setting: .guiOpenTerminalShortcut)
        newTabShortcutSpec = loadShortcutSpec(resolver, setting: .guiNewTabShortcut)
        openFinderShortcutSpec = loadShortcutSpec(resolver, setting: .guiOpenFinderShortcut)
        openSettingsShortcutSpec = loadShortcutSpec(resolver, setting: .guiOpenSettingsShortcut)
        windowShortcutSpec = loadShortcutSpec(resolver, setting: .guiWindowShortcut)
    }

    private func loadShortcutSpec(_ resolver: ShortcutSettingResolver, setting: ShortcutSetting) -> HotkeySpec? {
        Self.resolvedShortcutSpec(resolver, setting: setting, current: shortcutSpec(for: setting), leaderModifiers: shortcutLeaderModifiers)
    }

    /// The chord a shortcut setting is bound to after a load pass, given the one it is bound to now.
    ///
    /// A read that throws is a transient client-database failure, not a preference, so the setting keeps
    /// `current`. Answering it with `defaultSpec` instead would drop the leader modifiers that
    /// `rawValue(for:)` applies to leader-backed settings and degrade the whole table to bare letters
    /// until the next successful read — a stray "a" would open Alerts. On the launch pass nothing is in
    /// effect yet, so a throwing read installs the safe default instead of nil — composed with
    /// `leaderModifiers` for a leader-backed setting, never the bare key — or the global summon and
    /// palette hotkeys would go unregistered for the life of the outage. `defaultSpec` still answers the
    /// genuinely-unset setting, which `rawValue(for:)` resolves without throwing, and a stored value too
    /// malformed to parse.
    nonisolated static func resolvedShortcutSpec(
        _ resolver: ShortcutSettingResolver, setting: ShortcutSetting, current: HotkeySpec?, leaderModifiers: Set<HotkeyModifier>
    ) -> HotkeySpec? {
        guard let raw = try? resolver.rawValue(for: setting) else {
            if let current { return current }
            guard let defaultSpec = try? HotkeySpec.parse(setting.defaultSpec) else { return nil }
            return setting.usesLeader ? defaultSpec.adding(modifiers: leaderModifiers) : defaultSpec
        }
        if let stored = try? HotkeySpec.parse(raw) { return stored }
        return try? HotkeySpec.parse(setting.defaultSpec)
    }

    private func setShortcutSetting(setting: ShortcutSetting, value: String?) throws {
        let normalized = try shortcutSettingResolver().normalizedValue(for: setting, rawValue: value)
        try database().setSetting(key: setting.settingKey, value: normalized)
    }

    // The client database is resolved once, eagerly, when the resolver is built rather than lazily
    // inside `value` — so every setting this resolver reads (an entire `loadShortcutSpecs()` pass, or
    // a single `setShortcutSetting()` write) shares one handle instead of calling `clientDatabase()`
    // per read.
    private func shortcutSettingResolver() -> ShortcutSettingResolver {
        let database = Result { try self.database() }
        return ShortcutSettingResolver(value: { key in try database.get().setting(key: key) })
    }

    private func shortcutSpec(for setting: ShortcutSetting) -> HotkeySpec? {
        switch setting {
        case .guiHotkey: return toggleShortcutSpec
        case .guiCommandPaletteHotkey: return commandPaletteShortcutSpec
        case .guiLeaderHotkey: return nil
        case .guiAlertsShortcut: return host.alerts.alertsShortcutSpec
        case .guiAddWorkspaceShortcut: return addWorkspaceShortcutSpec
        case .guiReloadShortcut: return reloadShortcutSpec
        case .guiNextShortcut: return nextShortcutSpec
        case .guiPreviousShortcut: return previousShortcutSpec
        case .guiSidebarNextShortcut: return sidebarNextShortcutSpec
        case .guiSidebarPreviousShortcut: return sidebarPreviousShortcutSpec
        case .guiOpenEditorShortcut: return openEditorShortcutSpec
        case .guiOpenTerminalShortcut: return openTerminalShortcutSpec
        case .guiNewTabShortcut: return newTabShortcutSpec
        case .guiOpenFinderShortcut: return openFinderShortcutSpec
        case .guiOpenSettingsShortcut: return openSettingsShortcutSpec
        case .guiWindowShortcut: return windowShortcutSpec
        }
    }

    func matches(event: NSEvent, spec: HotkeySpec) -> Bool {
        guard UInt32(event.keyCode) == spec.keyCode else { return false }
        let flags = eventModifierCarbonFlags(event)
        return flags == spec.modifiersCarbon
    }

    // Not private: `AppKitController.numberedWindowShortcutIndex` calls this from a different file in
    // the same module (cross-file `private` isn't visible).
    func eventModifierCarbonFlags(_ event: NSEvent) -> UInt32 {
        var result: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    // Not private: `AppKitController.buildShortcutRowsContainer` calls this from a different file in
    // the same module (cross-file `private` isn't visible).
    func shortcutCaptureButtonTitle(setting: ShortcutSetting) -> String {
        if activeShortcutCaptureSetting == setting {
            if setting.capturesModifierOnly, !pendingLeaderCaptureModifiers.isEmpty {
                return displayShortcutText(modifiers: pendingLeaderCaptureModifiers)
            }
            return setting.capturesModifierOnly ? "Hold modifiers" : "Press shortcut"
        }
        return shortcutDisplayText(for: setting)
    }

    private func shortcutDisplayText(for setting: ShortcutSetting) -> String {
        if setting == .guiLeaderHotkey { return displayShortcutText(modifiers: shortcutLeaderModifiers) }
        guard let spec = shortcutSpec(for: setting) else { return setting.defaultSpec }
        if setting.usesDigitRangeCapture { return displayShortcutText(spec, keyText: "1-0") }
        return spec.normalized
    }

    private func actionTitle(base: String, setting: ShortcutSetting) -> String { "\(base) (\(shortcutHint(for: setting)))" }

    private func shortcutHint(for setting: ShortcutSetting) -> String {
        if setting == .guiLeaderHotkey { return displayShortcut(modifiers: shortcutLeaderModifiers) }
        guard let spec = shortcutSpec(for: setting) else { return setting.defaultSpec }
        if setting.usesDigitRangeCapture { return displayShortcut(spec, keyText: "1-0") }
        return displayShortcut(spec)
    }

    func footerShortcutHint(for setting: ShortcutSetting) -> String {
        if setting == .guiLeaderHotkey { return displayShortcut(modifiers: shortcutLeaderModifiers, separator: " ") }
        guard let spec = shortcutSpec(for: setting) else { return setting.defaultSpec }
        if setting.usesDigitRangeCapture { return displayShortcut(spec, separator: " ", keyText: "1-0") }
        return displayShortcut(spec, separator: " ")
    }

    private func displayShortcut(_ spec: HotkeySpec) -> String { displayShortcut(spec, separator: "") }

    // Not private: `AppKitController.windowShortcutBadgeText` calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func displayShortcut(_ spec: HotkeySpec, keyText: String) -> String { displayShortcut(spec, separator: "", keyText: keyText) }

    private func displayShortcut(_ spec: HotkeySpec, separator: String) -> String {
        displayShortcut(spec, separator: separator, keyText: displayShortcutKey(spec.key))
    }

    private func displayShortcut(_ spec: HotkeySpec, separator: String, keyText: String) -> String {
        displayShortcut(modifiers: spec.modifiers, separator: separator, keyText: keyText)
    }

    private func displayShortcut(modifiers: Set<HotkeyModifier>) -> String { displayShortcut(modifiers: modifiers, separator: "") }

    private func displayShortcut(modifiers: Set<HotkeyModifier>, separator: String) -> String {
        displayShortcut(modifiers: modifiers, separator: separator, keyText: nil)
    }

    private func displayShortcut(modifiers: Set<HotkeyModifier>, separator: String, keyText: String?) -> String {
        var parts: [String] = []
        if modifiers.contains(.cmd) { parts.append("⌘") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.alt) { parts.append("⌥") }
        if modifiers.contains(.ctrl) { parts.append("⌃") }
        if let keyText { parts.append(keyText) }
        return parts.joined(separator: separator)
    }

    private func displayShortcutText(_ spec: HotkeySpec, keyText: String) -> String {
        displayShortcutText(modifiers: spec.modifiers, keyText: keyText)
    }

    private func displayShortcutText(modifiers: Set<HotkeyModifier>) -> String { displayShortcutText(modifiers: modifiers, keyText: nil) }

    private func displayShortcutText(modifiers: Set<HotkeyModifier>, keyText: String?) -> String {
        var parts: [String] = []
        if modifiers.contains(.cmd) { parts.append("cmd") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.alt) { parts.append("alt") }
        if modifiers.contains(.ctrl) { parts.append("ctrl") }
        if let keyText { parts.append(keyText) }
        return parts.joined(separator: "+")
    }

    private func displayShortcutKey(_ key: String) -> String {
        switch key {
        case "return", "enter": return "↩"
        case "space": return "Space"
        case "tab": return "⇥"
        case "escape": return "⎋"
        case "delete", "backspace": return "⌫"
        case "forwarddelete": return "⌦"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "minus": return "-"
        default: return key.uppercased()
        }
    }

    @objc func beginShortcutCapture(_ sender: NSButton) {
        guard let settingKey = sender.identifier?.rawValue, let setting = ShortcutSetting(settingKey: settingKey) else { return }

        pendingLeaderCaptureModifiers = []
        if activeShortcutCaptureSetting == setting { activeShortcutCaptureSetting = nil } else { activeShortcutCaptureSetting = setting }
        refreshShortcutCaptureButtons()
    }

    @objc func resetShortcutSetting(_ sender: NSButton) {
        guard let settingKey = sender.identifier?.rawValue, let setting = ShortcutSetting(settingKey: settingKey) else { return }

        if activeShortcutCaptureSetting == setting {
            pendingLeaderCaptureModifiers = []
            activeShortcutCaptureSetting = nil
            refreshShortcutCaptureButtons()
        }

        do {
            try setShortcutSetting(setting: setting, value: nil)
            pendingLeaderCaptureModifiers = []
            loadShortcutSpecs()
            setupGlobalHotkey()
            host.refreshSelection()
        } catch { host.showError(error) }
    }

    private func refreshShortcutCaptureButtons() {
        for (settingKey, button) in shortcutButtonsBySetting {
            guard let setting = ShortcutSetting(settingKey: settingKey) else { continue }
            let isActive = activeShortcutCaptureSetting == setting
            updateShortcutCaptureButtonText(button, text: shortcutCaptureButtonTitle(setting: setting), active: isActive)
            styleShortcutCaptureButton(button, active: isActive)
            if activeShortcutCaptureSetting == setting {
                button.toolTip =
                    setting.capturesModifierOnly ? "Hold a modifier combination (Esc to cancel)" : "Press a key combination (Esc to cancel)"
            } else {
                button.toolTip = "Click to capture shortcut"
            }
        }
    }

    // Not private: `AppKitController.buildShortcutRowsContainer` calls this from a different file in
    // the same module (cross-file `private` isn't visible).
    func styleShortcutCaptureButton(_ button: NSButton, active: Bool) {
        button.wantsLayer = true
        button.layer?.cornerRadius = UIRadius.compact
        button.layer?.borderWidth = 1
        bindAppearanceReactiveLayer(button) { [weak self] view in
            view.layer?.backgroundColor = self?.shortcutKeycapBackgroundColor(active: active).cgColor
            view.layer?.borderColor = self?.shortcutKeycapBorderColor(active: active).cgColor
        }
    }

    // Not private: `AppKitController.buildShortcutRowsContainer` calls this from a different file in
    // the same module (cross-file `private` isn't visible).
    func updateShortcutCaptureButtonText(_ button: NSButton, text: String, active: Bool) {
        let color: NSColor = active ? .white : .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color, .font: Typography.monoBody, .paragraphStyle: paragraph]
        button.attributedTitle = NSAttributedString(string: "  \(text)  ", attributes: attrs)
    }

    private func shortcutKeycapBackgroundColor(active: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if active {
                return isDark
                    ? NSColor(calibratedRed: 0.13, green: 0.28, blue: 0.42, alpha: 1.0)
                    : NSColor(calibratedRed: 0.80, green: 0.89, blue: 0.97, alpha: 1.0)
            }
            return isDark ? NSColor(calibratedWhite: 0.16, alpha: 1.0) : NSColor(calibratedWhite: 0.82, alpha: 1.0)
        }
    }

    private func shortcutKeycapBorderColor(active: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            if active { return .systemBlue }
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(calibratedWhite: 0.28, alpha: 1.0) : NSColor(calibratedWhite: 0.65, alpha: 1.0)
        }
    }
}
