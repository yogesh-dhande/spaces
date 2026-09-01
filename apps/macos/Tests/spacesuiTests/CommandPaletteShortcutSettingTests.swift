import Testing
import spacesclientcore

@testable import spacesui

@Suite struct CommandPaletteShortcutSettingTests {
    @Test func commandPaletteShortcutSettingMapsToClientSettingsKey() {
        #expect(ShortcutsController.ShortcutSetting(settingKey: ClientSettingsKey.guiCommandPaletteHotkey) == .guiCommandPaletteHotkey)
        #expect(ShortcutsController.ShortcutSetting.guiCommandPaletteHotkey.settingKey == ClientSettingsKey.guiCommandPaletteHotkey)
        #expect(ShortcutsController.ShortcutSetting.guiCommandPaletteHotkey.defaultSpec == ClientSettingsKey.defaultGUICommandPaletteHotkey)
    }

    @Test func commandPaletteShortcutAppearsInSettingsPanel() {
        let cases = ShortcutsController.ShortcutSetting.settingsPanelCases
        let hotkeyIndex = cases.firstIndex(of: .guiHotkey)
        let commandPaletteIndex = cases.firstIndex(of: .guiCommandPaletteHotkey)

        #expect(hotkeyIndex != nil)
        #expect(commandPaletteIndex != nil)
        #expect(commandPaletteIndex == hotkeyIndex.map { $0 + 1 })
    }

    @Test func sidebarNavigationShortcutsAreConfigurableInSettingsPanel() {
        // Sidebar selection moves only via leader+up/down, so those shortcuts must be user-overridable
        // from the settings panel rather than hidden functional-only bindings.
        let cases = ShortcutsController.ShortcutSetting.settingsPanelCases
        #expect(cases.contains(.guiSidebarNextShortcut))
        #expect(cases.contains(.guiSidebarPreviousShortcut))
    }

    @Test func commandPaletteDismissShortcutUsesCommandXRegardlessOfLeader() {
        #expect(AppKitController.commandPaletteDismissShortcutMatches(charactersIgnoringModifiers: "x", modifiers: [.cmd], selectedItemIsAlert: true))
        #expect(
            !AppKitController.commandPaletteDismissShortcutMatches(charactersIgnoringModifiers: "x", modifiers: [.cmd], selectedItemIsAlert: false))
        #expect(
            !AppKitController.commandPaletteDismissShortcutMatches(
                charactersIgnoringModifiers: "x", modifiers: [.cmd, .alt], selectedItemIsAlert: true))
        #expect(
            !AppKitController.commandPaletteDismissShortcutMatches(
                charactersIgnoringModifiers: "x", modifiers: [.cmd, .shift], selectedItemIsAlert: true))
        #expect(
            !AppKitController.commandPaletteDismissShortcutMatches(charactersIgnoringModifiers: "c", modifiers: [.cmd], selectedItemIsAlert: true))
    }

    @Test func commandXPreservesCutWhenPaletteSearchHasSelectedText() {
        #expect(
            !AppKitController.commandPaletteDismissShortcutMatches(
                charactersIgnoringModifiers: "x", modifiers: [.cmd], selectedItemIsAlert: true, searchEditorCanCutSelectedText: true))
        #expect(
            AppKitController.commandPaletteDismissShortcutMatches(
                charactersIgnoringModifiers: "x", modifiers: [.cmd], selectedItemIsAlert: true, searchEditorCanCutSelectedText: false))
    }

    @Test func shortcutLeaderSettingRequiresAtLeastTwoModifiers() throws {
        let resolver = ShortcutsController.ShortcutSettingResolver { key in key == ClientSettingsKey.guiLeaderHotkey ? "ctrl" : nil }
        do {
            _ = try resolver.normalizedValue(for: .guiLeaderHotkey, rawValue: "ctrl")
            Issue.record("expected single-modifier leader to be rejected")
        } catch { #expect(error.localizedDescription == "Hotkey leader must contain at least two modifiers") }
    }

    @Test func shortcutLeaderSettingNormalizesModifierOrder() throws {
        let resolver = ShortcutsController.ShortcutSettingResolver { _ in nil }
        let normalized = try resolver.normalizedValue(for: .guiLeaderHotkey, rawValue: "control option")
        #expect(normalized == "alt+ctrl")
    }
}
