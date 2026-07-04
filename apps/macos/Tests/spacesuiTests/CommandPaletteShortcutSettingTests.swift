import Testing
import workspacecore

@testable import spacesui

@Suite struct CommandPaletteShortcutSettingTests {
    @Test func commandPaletteShortcutSettingMapsToWorkspacecoreKey() {
        #expect(AppKitController.ShortcutSetting(settingKey: SettingsKey.guiCommandPaletteHotkey) == .guiCommandPaletteHotkey)
        #expect(AppKitController.ShortcutSetting.guiCommandPaletteHotkey.settingKey == SettingsKey.guiCommandPaletteHotkey)
        #expect(AppKitController.ShortcutSetting.guiCommandPaletteHotkey.defaultSpec == SettingsKey.defaultGUICommandPaletteHotkey)
    }

    @Test func commandPaletteShortcutAppearsInSettingsPanel() {
        let cases = AppKitController.ShortcutSetting.settingsPanelCases
        let hotkeyIndex = cases.firstIndex(of: .guiHotkey)
        let commandPaletteIndex = cases.firstIndex(of: .guiCommandPaletteHotkey)

        #expect(hotkeyIndex != nil)
        #expect(commandPaletteIndex != nil)
        #expect(commandPaletteIndex == hotkeyIndex.map { $0 + 1 })
    }

    @Test func commandPaletteDismissShortcutUsesLeaderPlusX() {
        #expect(
            AppKitController.commandPaletteDismissShortcutMatches(
                charactersIgnoringModifiers: "x", modifiers: [.cmd, .alt], leaderModifiers: [.cmd, .alt]))
        #expect(
            !AppKitController.commandPaletteDismissShortcutMatches(
                charactersIgnoringModifiers: "x", modifiers: [.cmd], leaderModifiers: [.cmd, .alt]))
        #expect(
            !AppKitController.commandPaletteDismissShortcutMatches(
                charactersIgnoringModifiers: "x", modifiers: [.cmd, .alt, .shift], leaderModifiers: [.cmd, .alt]))
        #expect(
            !AppKitController.commandPaletteDismissShortcutMatches(
                charactersIgnoringModifiers: "c", modifiers: [.cmd, .alt], leaderModifiers: [.cmd, .alt]))
    }

    @Test func shortcutLeaderSettingRequiresAtLeastTwoModifiers() throws {
        let resolver = AppKitController.ShortcutSettingResolver { key in
            key == SettingsKey.guiLeaderHotkey ? "ctrl" : nil
        }
        do {
            _ = try resolver.normalizedValue(for: .guiLeaderHotkey, rawValue: "ctrl")
            Issue.record("expected single-modifier leader to be rejected")
        } catch {
            #expect(error.localizedDescription == "Hotkey leader must contain at least two modifiers")
        }
    }

    @Test func shortcutLeaderSettingNormalizesModifierOrder() throws {
        let resolver = AppKitController.ShortcutSettingResolver { _ in nil }
        let normalized = try resolver.normalizedValue(for: .guiLeaderHotkey, rawValue: "control option")
        #expect(normalized == "alt+ctrl")
    }
}
