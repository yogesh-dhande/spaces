import AppKit
import Testing
import workspacecore

@testable import spacesui

@Suite struct ShortcutMonitorDispositionTests {
    @Test func nonTerminalFocusAlwaysRunsAppShortcuts() {
        #expect(ShortcutsController.shortcutMonitorDisposition(eventModifiers: [], firstResponderIsTerminalPane: false) == .runAppShortcuts)
        #expect(ShortcutsController.shortcutMonitorDisposition(eventModifiers: [.command], firstResponderIsTerminalPane: false) == .runAppShortcuts)
        #expect(ShortcutsController.shortcutMonitorDisposition(eventModifiers: [.control], firstResponderIsTerminalPane: false) == .runAppShortcuts)
    }

    @Test func focusedTerminalOwnsEveryNonCommandKey() {
        #expect(ShortcutsController.shortcutMonitorDisposition(eventModifiers: [], firstResponderIsTerminalPane: true) == .passEventToTerminal)
        #expect(ShortcutsController.shortcutMonitorDisposition(eventModifiers: [.control], firstResponderIsTerminalPane: true) == .passEventToTerminal)
        #expect(ShortcutsController.shortcutMonitorDisposition(eventModifiers: [.option], firstResponderIsTerminalPane: true) == .passEventToTerminal)
        #expect(ShortcutsController.shortcutMonitorDisposition(eventModifiers: [.shift], firstResponderIsTerminalPane: true) == .passEventToTerminal)
    }

    @Test func focusedTerminalRunsAppShortcutsThenPaneHandlingForConfiguredNonCommandLeader() {
        let leaderModifiers: Set<HotkeyModifier> = [.ctrl, .alt]
        #expect(
            ShortcutsController.shortcutMonitorDisposition(
                eventModifiers: [.control, .option], firstResponderIsTerminalPane: true, shortcutLeaderModifiers: leaderModifiers)
                == .runAppShortcutsThenTerminal)
        #expect(
            ShortcutsController.shortcutMonitorDisposition(
                eventModifiers: [.control, .option, .shift], firstResponderIsTerminalPane: true, shortcutLeaderModifiers: leaderModifiers)
                == .runAppShortcutsThenTerminal)
        #expect(
            ShortcutsController.shortcutMonitorDisposition(
                eventModifiers: [.control], firstResponderIsTerminalPane: true, shortcutLeaderModifiers: leaderModifiers) == .passEventToTerminal)
    }

    @Test func commandChordsRunAppShortcutsEvenWithTerminalFocus() {
        #expect(ShortcutsController.shortcutMonitorDisposition(eventModifiers: [.command], firstResponderIsTerminalPane: true) == .runAppShortcuts)
        #expect(
            ShortcutsController.shortcutMonitorDisposition(eventModifiers: [.command, .option], firstResponderIsTerminalPane: true) == .runAppShortcuts)
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

    // MARK: - ⌘T new-tab session picker gating

    @Test func newTabShortcutConsumesWhilePickerIsActiveRegardlessOfEverythingElse() {
        #expect(
            AppKitController.newTabShortcutAction(
                sessionPickerIsActive: true, textInputIsFocused: true, keyWindowIsPanelWindow: true, keyWindowIsMainWindow: false,
                selectedWorkspaceID: nil) == .consume)
        #expect(
            AppKitController.newTabShortcutAction(
                sessionPickerIsActive: true, textInputIsFocused: false, keyWindowIsPanelWindow: false, keyWindowIsMainWindow: true,
                selectedWorkspaceID: "workspace-1") == .consume)
    }

    @Test func newTabShortcutPassesWhenAFocusedTextInputIsNotThePicker() {
        #expect(
            AppKitController.newTabShortcutAction(
                sessionPickerIsActive: false, textInputIsFocused: true, keyWindowIsPanelWindow: false, keyWindowIsMainWindow: true,
                selectedWorkspaceID: "workspace-1") == .pass)
    }

    @Test func newTabShortcutConsumesWhenAPanelWindowIsKey() {
        #expect(
            AppKitController.newTabShortcutAction(
                sessionPickerIsActive: false, textInputIsFocused: false, keyWindowIsPanelWindow: true, keyWindowIsMainWindow: false,
                selectedWorkspaceID: nil) == .consume)
    }

    @Test func newTabShortcutPresentsPickerForMainWindowWithSelectedWorkspace() {
        #expect(
            AppKitController.newTabShortcutAction(
                sessionPickerIsActive: false, textInputIsFocused: false, keyWindowIsPanelWindow: false, keyWindowIsMainWindow: true,
                selectedWorkspaceID: "workspace-1") == .presentPicker)
    }

    @Test func newTabShortcutPassesForMainWindowWithoutASelectedWorkspace() {
        #expect(
            AppKitController.newTabShortcutAction(
                sessionPickerIsActive: false, textInputIsFocused: false, keyWindowIsPanelWindow: false, keyWindowIsMainWindow: true,
                selectedWorkspaceID: nil) == .pass)
    }

    @Test func newTabShortcutPassesWhenNeitherWindowKindIsKey() {
        #expect(
            AppKitController.newTabShortcutAction(
                sessionPickerIsActive: false, textInputIsFocused: false, keyWindowIsPanelWindow: false, keyWindowIsMainWindow: false,
                selectedWorkspaceID: "workspace-1") == .pass)
    }
}
