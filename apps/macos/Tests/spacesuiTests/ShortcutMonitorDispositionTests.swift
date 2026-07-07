import AppKit
import Testing
import workspacecore

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

    @Test func focusedTerminalRunsAppShortcutsThenPaneHandlingForConfiguredNonCommandLeader() {
        let leaderModifiers: Set<HotkeyModifier> = [.ctrl, .alt]
        #expect(
            AppKitController.shortcutMonitorDisposition(
                eventModifiers: [.control, .option], firstResponderIsTerminalPane: true, shortcutLeaderModifiers: leaderModifiers)
                == .runAppShortcutsThenTerminal)
        #expect(
            AppKitController.shortcutMonitorDisposition(
                eventModifiers: [.control, .option, .shift], firstResponderIsTerminalPane: true, shortcutLeaderModifiers: leaderModifiers)
                == .runAppShortcutsThenTerminal)
        #expect(
            AppKitController.shortcutMonitorDisposition(
                eventModifiers: [.control], firstResponderIsTerminalPane: true, shortcutLeaderModifiers: leaderModifiers) == .passEventToTerminal)
    }

    @Test func commandChordsRunAppShortcutsEvenWithTerminalFocus() {
        #expect(AppKitController.shortcutMonitorDisposition(eventModifiers: [.command], firstResponderIsTerminalPane: true) == .runAppShortcuts)
        #expect(
            AppKitController.shortcutMonitorDisposition(eventModifiers: [.command, .option], firstResponderIsTerminalPane: true) == .runAppShortcuts)
    }

    @Test func closePaneShortcutMatchesPlainCommandWOnly() {
        #expect(AppKitController.isClosePaneShortcut(charactersIgnoringModifiers: "w", eventModifiers: [.command]))
        #expect(AppKitController.isClosePaneShortcut(charactersIgnoringModifiers: "W", eventModifiers: [.command, .capsLock]))
        #expect(!AppKitController.isClosePaneShortcut(charactersIgnoringModifiers: "w", eventModifiers: []))
        #expect(!AppKitController.isClosePaneShortcut(charactersIgnoringModifiers: "w", eventModifiers: [.command, .shift]))
        #expect(!AppKitController.isClosePaneShortcut(charactersIgnoringModifiers: "w", eventModifiers: [.command, .option]))
        #expect(!AppKitController.isClosePaneShortcut(charactersIgnoringModifiers: "q", eventModifiers: [.command]))
        #expect(!AppKitController.isClosePaneShortcut(charactersIgnoringModifiers: nil, eventModifiers: [.command]))
    }
}
