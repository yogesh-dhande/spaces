import Foundation
import workspacecore

extension AppKitController {
    enum ShortcutSetting: CaseIterable {
        case guiHotkey
        case guiCommandPaletteHotkey
        case guiLeaderHotkey
        case guiAlertsShortcut
        case guiAddWorkspaceShortcut
        case guiReloadShortcut
        case guiNextShortcut
        case guiPreviousShortcut
        case guiSidebarNextShortcut
        case guiSidebarPreviousShortcut
        case guiOpenEditorShortcut
        case guiOpenTerminalShortcut
        case guiOpenFinderShortcut
        case guiOpenSettingsShortcut
        case guiWindowShortcut

        var label: String {
            switch self {
            case .guiHotkey: return "Toggle app"
            case .guiCommandPaletteHotkey: return "Open command palette"
            case .guiLeaderHotkey: return "Shortcut leader"
            case .guiAlertsShortcut: return "Show alerts"
            case .guiAddWorkspaceShortcut: return "New workspace"
            case .guiReloadShortcut: return "Reload data"
            case .guiNextShortcut: return "Next window"
            case .guiPreviousShortcut: return "Previous window"
            case .guiSidebarNextShortcut: return "Next workspace"
            case .guiSidebarPreviousShortcut: return "Previous workspace"
            case .guiOpenEditorShortcut: return "Open editor"
            case .guiOpenTerminalShortcut: return "New terminal"
            case .guiOpenFinderShortcut: return "Open Finder"
            case .guiOpenSettingsShortcut: return "Open settings"
            case .guiWindowShortcut: return "Focus window 1-9"
            }
        }

        static let settingsPanelCases: [ShortcutSetting] = [
            .guiLeaderHotkey, .guiHotkey, .guiCommandPaletteHotkey, .guiNextShortcut, .guiPreviousShortcut, .guiOpenEditorShortcut,
            .guiAlertsShortcut, .guiAddWorkspaceShortcut, .guiReloadShortcut, .guiOpenTerminalShortcut, .guiOpenFinderShortcut,
            .guiOpenSettingsShortcut, .guiWindowShortcut,
        ]

        var usesLeader: Bool {
            switch self {
            case .guiAlertsShortcut, .guiNextShortcut, .guiPreviousShortcut, .guiSidebarNextShortcut, .guiSidebarPreviousShortcut,
                .guiOpenEditorShortcut, .guiOpenTerminalShortcut, .guiOpenFinderShortcut, .guiReloadShortcut:
                return true
            default: return false
            }
        }

        var capturesModifierOnly: Bool {
            switch self {
            case .guiLeaderHotkey: return true
            default: return false
            }
        }

        var usesDigitRangeCapture: Bool {
            switch self {
            case .guiWindowShortcut: return true
            default: return false
            }
        }

        var settingKey: String {
            switch self {
            case .guiHotkey: return SettingsKey.guiHotkey
            case .guiCommandPaletteHotkey: return SettingsKey.guiCommandPaletteHotkey
            case .guiLeaderHotkey: return SettingsKey.guiLeaderHotkey
            case .guiAlertsShortcut: return SettingsKey.guiAlertsShortcut
            case .guiAddWorkspaceShortcut: return SettingsKey.guiAddWorkspaceShortcut
            case .guiReloadShortcut: return SettingsKey.guiReloadShortcut
            case .guiNextShortcut: return SettingsKey.guiNextShortcut
            case .guiPreviousShortcut: return SettingsKey.guiPreviousShortcut
            case .guiSidebarNextShortcut: return SettingsKey.guiSidebarNextShortcut
            case .guiSidebarPreviousShortcut: return SettingsKey.guiSidebarPreviousShortcut
            case .guiOpenEditorShortcut: return SettingsKey.guiOpenEditorShortcut
            case .guiOpenTerminalShortcut: return SettingsKey.guiOpenTerminalShortcut
            case .guiOpenFinderShortcut: return SettingsKey.guiOpenFinderShortcut
            case .guiOpenSettingsShortcut: return SettingsKey.guiOpenSettingsShortcut
            case .guiWindowShortcut: return SettingsKey.guiWindowShortcut
            }
        }

        var defaultSpec: String {
            switch self {
            case .guiHotkey: return SettingsKey.defaultGUIHotkey
            case .guiCommandPaletteHotkey: return SettingsKey.defaultGUICommandPaletteHotkey
            case .guiLeaderHotkey: return SettingsKey.defaultGUILeaderHotkey
            case .guiAlertsShortcut: return SettingsKey.defaultGUIAlertsShortcut
            case .guiAddWorkspaceShortcut: return SettingsKey.defaultGUIAddWorkspaceShortcut
            case .guiReloadShortcut: return SettingsKey.defaultGUIReloadShortcut
            case .guiNextShortcut: return SettingsKey.defaultGUINextShortcut
            case .guiPreviousShortcut: return SettingsKey.defaultGUIPreviousShortcut
            case .guiSidebarNextShortcut: return SettingsKey.defaultGUISidebarNextShortcut
            case .guiSidebarPreviousShortcut: return SettingsKey.defaultGUISidebarPreviousShortcut
            case .guiOpenEditorShortcut: return SettingsKey.defaultGUIOpenEditorShortcut
            case .guiOpenTerminalShortcut: return SettingsKey.defaultGUIOpenTerminalShortcut
            case .guiOpenFinderShortcut: return SettingsKey.defaultGUIOpenFinderShortcut
            case .guiOpenSettingsShortcut: return SettingsKey.defaultGUIOpenSettingsShortcut
            case .guiWindowShortcut: return SettingsKey.defaultGUIWindowShortcut
            }
        }

        init?(settingKey: String) {
            switch settingKey {
            case SettingsKey.guiHotkey: self = .guiHotkey
            case SettingsKey.guiCommandPaletteHotkey: self = .guiCommandPaletteHotkey
            case SettingsKey.guiLeaderHotkey: self = .guiLeaderHotkey
            case SettingsKey.guiAlertsShortcut: self = .guiAlertsShortcut
            case SettingsKey.guiAddWorkspaceShortcut: self = .guiAddWorkspaceShortcut
            case SettingsKey.guiReloadShortcut: self = .guiReloadShortcut
            case SettingsKey.guiNextShortcut: self = .guiNextShortcut
            case SettingsKey.guiPreviousShortcut: self = .guiPreviousShortcut
            case SettingsKey.guiSidebarNextShortcut: self = .guiSidebarNextShortcut
            case SettingsKey.guiSidebarPreviousShortcut: self = .guiSidebarPreviousShortcut
            case SettingsKey.guiOpenEditorShortcut: self = .guiOpenEditorShortcut
            case SettingsKey.guiOpenTerminalShortcut: self = .guiOpenTerminalShortcut
            case SettingsKey.guiOpenFinderShortcut: self = .guiOpenFinderShortcut
            case SettingsKey.guiOpenSettingsShortcut: self = .guiOpenSettingsShortcut
            case SettingsKey.guiWindowShortcut: self = .guiWindowShortcut
            default: return nil
            }
        }
    }

    struct ShortcutSettingResolver {
        let value: (String) throws -> String?

        func rawValue(for setting: ShortcutSetting) throws -> String {
            if setting.usesLeader { return try effectiveLeaderBackedShortcut(setting: setting) }
            return try value(setting.settingKey) ?? setting.defaultSpec
        }

        func normalizedValue(for setting: ShortcutSetting, rawValue: String?) throws -> String? {
            guard setting.usesLeader else { return rawValue }
            return try normalizedLeaderBackedShortcut(rawValue)
        }

        func leaderModifiers() throws -> Set<HotkeyModifier> {
            if let raw = try value(SettingsKey.guiLeaderHotkey), let modifiers = try? HotkeySpec.parseModifierSet(raw), !modifiers.isEmpty {
                return modifiers
            }
            return try HotkeySpec.parseModifierSet(SettingsKey.defaultGUILeaderHotkey)
        }

        private func effectiveLeaderBackedShortcut(setting: ShortcutSetting) throws -> String {
            let leaderModifiers = try leaderModifiers()
            guard let raw = try value(setting.settingKey), let stored = try? HotkeySpec.parse(raw) else {
                let spec = (try? HotkeySpec.parse(setting.defaultSpec)) ?? HotkeySpec(key: setting.defaultSpec, modifiers: [])
                return spec.adding(modifiers: leaderModifiers).normalized
            }
            if stored.modifiers.isEmpty { return stored.adding(modifiers: leaderModifiers).normalized }
            if stored.modifiers.isSuperset(of: leaderModifiers) {
                return stored.removing(modifiers: leaderModifiers).adding(modifiers: leaderModifiers).normalized
            }
            return stored.normalized
        }

        private func normalizedLeaderBackedShortcut(_ raw: String?) throws -> String? {
            guard let raw else { return nil }
            let spec = try HotkeySpec.parse(raw)
            let leaderModifiers = try leaderModifiers()
            if spec.modifiers.isSuperset(of: leaderModifiers) { return spec.removing(modifiers: leaderModifiers).normalized }
            return spec.normalized
        }
    }
}
