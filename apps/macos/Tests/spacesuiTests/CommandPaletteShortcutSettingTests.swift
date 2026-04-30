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
}
