import AppKit
import Testing

@testable import spacesui

@Suite struct ShortcutMonitorDispositionTests {
    @Test func nonTerminalFocusAlwaysRunsAppShortcuts() {
        #expect(AppKitController.shortcutMonitorDisposition(eventModifiers: [], firstResponderIsTerminalPane: false) == .runAppShortcuts)
        #expect(AppKitController.shortcutMonitorDisposition(eventModifiers: [.command], firstResponderIsTerminalPane: false) == .runAppShortcuts)
        #expect(AppKitController.shortcutMonitorDisposition(eventModifiers: [.control], firstResponderIsTerminalPane: false) == .runAppShortcuts)
    }

    @Test func focusedTerminalOwnsEveryNonCommandKey() {
        #expect(AppKitController.shortcutMonitorDisposition(eventModifiers: [], firstResponderIsTerminalPane: true) == .passEventToTerminal)
        #expect(AppKitController.shortcutMonitorDisposition(eventModifiers: [.control], firstResponderIsTerminalPane: true) == .passEventToTerminal)
        #expect(AppKitController.shortcutMonitorDisposition(eventModifiers: [.option], firstResponderIsTerminalPane: true) == .passEventToTerminal)
        #expect(AppKitController.shortcutMonitorDisposition(eventModifiers: [.shift], firstResponderIsTerminalPane: true) == .passEventToTerminal)
    }

    @Test func commandChordsRunAppShortcutsEvenWithTerminalFocus() {
        #expect(AppKitController.shortcutMonitorDisposition(eventModifiers: [.command], firstResponderIsTerminalPane: true) == .runAppShortcuts)
        #expect(
            AppKitController.shortcutMonitorDisposition(eventModifiers: [.command, .option], firstResponderIsTerminalPane: true)
                == .runAppShortcuts)
    }
}
