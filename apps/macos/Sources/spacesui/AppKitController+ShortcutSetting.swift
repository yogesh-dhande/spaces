import Foundation
import spacesclientcore
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
            case .guiWindowShortcut: return "Focus window 1-0"
            }
        }

        static let settingsPanelCases: [ShortcutSetting] = [
            .guiLeaderHotkey, .guiHotkey, .guiCommandPaletteHotkey, .guiNextShortcut, .guiPreviousShortcut, .guiSidebarNextShortcut,
            .guiSidebarPreviousShortcut, .guiOpenEditorShortcut, .guiAlertsShortcut, .guiAddWorkspaceShortcut, .guiReloadShortcut,
            .guiOpenTerminalShortcut, .guiOpenFinderShortcut, .guiOpenSettingsShortcut, .guiWindowShortcut,
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
            case .guiHotkey: return ClientSettingsKey.guiHotkey
            case .guiCommandPaletteHotkey: return ClientSettingsKey.guiCommandPaletteHotkey
            case .guiLeaderHotkey: return ClientSettingsKey.guiLeaderHotkey
            case .guiAlertsShortcut: return ClientSettingsKey.guiAlertsShortcut
            case .guiAddWorkspaceShortcut: return ClientSettingsKey.guiAddWorkspaceShortcut
            case .guiReloadShortcut: return ClientSettingsKey.guiReloadShortcut
            case .guiNextShortcut: return ClientSettingsKey.guiNextShortcut
            case .guiPreviousShortcut: return ClientSettingsKey.guiPreviousShortcut
            case .guiSidebarNextShortcut: return ClientSettingsKey.guiSidebarNextShortcut
            case .guiSidebarPreviousShortcut: return ClientSettingsKey.guiSidebarPreviousShortcut
            case .guiOpenEditorShortcut: return ClientSettingsKey.guiOpenEditorShortcut
            case .guiOpenTerminalShortcut: return ClientSettingsKey.guiOpenTerminalShortcut
            case .guiOpenFinderShortcut: return ClientSettingsKey.guiOpenFinderShortcut
            case .guiOpenSettingsShortcut: return ClientSettingsKey.guiOpenSettingsShortcut
            case .guiWindowShortcut: return ClientSettingsKey.guiWindowShortcut
            }
        }

        var defaultSpec: String {
            switch self {
            case .guiHotkey: return ClientSettingsKey.defaultGUIHotkey
            case .guiCommandPaletteHotkey: return ClientSettingsKey.defaultGUICommandPaletteHotkey
            case .guiLeaderHotkey: return ClientSettingsKey.defaultGUILeaderHotkey
            case .guiAlertsShortcut: return ClientSettingsKey.defaultGUIAlertsShortcut
            case .guiAddWorkspaceShortcut: return ClientSettingsKey.defaultGUIAddWorkspaceShortcut
            case .guiReloadShortcut: return ClientSettingsKey.defaultGUIReloadShortcut
            case .guiNextShortcut: return ClientSettingsKey.defaultGUINextShortcut
            case .guiPreviousShortcut: return ClientSettingsKey.defaultGUIPreviousShortcut
            case .guiSidebarNextShortcut: return ClientSettingsKey.defaultGUISidebarNextShortcut
            case .guiSidebarPreviousShortcut: return ClientSettingsKey.defaultGUISidebarPreviousShortcut
            case .guiOpenEditorShortcut: return ClientSettingsKey.defaultGUIOpenEditorShortcut
            case .guiOpenTerminalShortcut: return ClientSettingsKey.defaultGUIOpenTerminalShortcut
            case .guiOpenFinderShortcut: return ClientSettingsKey.defaultGUIOpenFinderShortcut
            case .guiOpenSettingsShortcut: return ClientSettingsKey.defaultGUIOpenSettingsShortcut
            case .guiWindowShortcut: return ClientSettingsKey.defaultGUIWindowShortcut
            }
        }

        init?(settingKey: String) {
            switch settingKey {
            case ClientSettingsKey.guiHotkey: self = .guiHotkey
            case ClientSettingsKey.guiCommandPaletteHotkey: self = .guiCommandPaletteHotkey
            case ClientSettingsKey.guiLeaderHotkey: self = .guiLeaderHotkey
            case ClientSettingsKey.guiAlertsShortcut: self = .guiAlertsShortcut
            case ClientSettingsKey.guiAddWorkspaceShortcut: self = .guiAddWorkspaceShortcut
            case ClientSettingsKey.guiReloadShortcut: self = .guiReloadShortcut
            case ClientSettingsKey.guiNextShortcut: self = .guiNextShortcut
            case ClientSettingsKey.guiPreviousShortcut: self = .guiPreviousShortcut
            case ClientSettingsKey.guiSidebarNextShortcut: self = .guiSidebarNextShortcut
            case ClientSettingsKey.guiSidebarPreviousShortcut: self = .guiSidebarPreviousShortcut
            case ClientSettingsKey.guiOpenEditorShortcut: self = .guiOpenEditorShortcut
            case ClientSettingsKey.guiOpenTerminalShortcut: self = .guiOpenTerminalShortcut
            case ClientSettingsKey.guiOpenFinderShortcut: self = .guiOpenFinderShortcut
            case ClientSettingsKey.guiOpenSettingsShortcut: self = .guiOpenSettingsShortcut
            case ClientSettingsKey.guiWindowShortcut: self = .guiWindowShortcut
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
            if setting == .guiLeaderHotkey { return try normalizedLeaderModifierSet(rawValue) }
            guard setting.usesLeader else { return rawValue }
            return try normalizedLeaderBackedShortcut(rawValue)
        }

        func leaderModifiers() throws -> Set<HotkeyModifier> {
            if let raw = try value(ClientSettingsKey.guiLeaderHotkey), let modifiers = try? HotkeySpec.parseModifierSet(raw), !modifiers.isEmpty {
                return modifiers
            }
            return try HotkeySpec.parseModifierSet(ClientSettingsKey.defaultGUILeaderHotkey)
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

        private func normalizedLeaderModifierSet(_ raw: String?) throws -> String? {
            guard let raw else { return nil }
            return try HotkeySpec.normalizedModifierSet(HotkeySpec.parseModifierSet(raw))
        }
    }
}
