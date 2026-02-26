import Foundation
import streamctl

extension AppKitController {
    enum ShortcutSetting: CaseIterable {
        case guiHotkey
        case guiShowShortcut
        case guiAddProjectShortcut
        case guiAddWorkspaceShortcut
        case guiReloadShortcut
        case guiNextShortcut
        case guiPreviousShortcut
        case guiOpenEditorShortcut
        case guiOpenTerminalShortcut
        case guiOpenFinderShortcut
        case guiOpenSettingsShortcut
        case guiTooltipShortcut

        var label: String {
            switch self {
            case .guiHotkey: return "Toggle app"
            case .guiShowShortcut: return "Focus selected workspace"
            case .guiAddProjectShortcut: return "New project"
            case .guiAddWorkspaceShortcut: return "New workspace"
            case .guiReloadShortcut: return "Reload data"
            case .guiNextShortcut: return "Next workspace"
            case .guiPreviousShortcut: return "Previous workspace"
            case .guiOpenEditorShortcut: return "Open editor"
            case .guiOpenTerminalShortcut: return "Open terminal"
            case .guiOpenFinderShortcut: return "Open Finder"
            case .guiOpenSettingsShortcut: return "Open settings"
            case .guiTooltipShortcut: return "Toggle tooltip"
            }
        }

        static let settingsPanelCases: [ShortcutSetting] = [
            .guiHotkey, .guiNextShortcut, .guiPreviousShortcut, .guiOpenEditorShortcut, .guiOpenTerminalShortcut, .guiOpenFinderShortcut,
            .guiOpenSettingsShortcut, .guiTooltipShortcut,
        ]

        var settingKey: String {
            switch self {
            case .guiHotkey: return SettingsKey.guiHotkey
            case .guiShowShortcut: return SettingsKey.guiShowShortcut
            case .guiAddProjectShortcut: return SettingsKey.guiAddProjectShortcut
            case .guiAddWorkspaceShortcut: return SettingsKey.guiAddWorkspaceShortcut
            case .guiReloadShortcut: return SettingsKey.guiReloadShortcut
            case .guiNextShortcut: return SettingsKey.guiNextShortcut
            case .guiPreviousShortcut: return SettingsKey.guiPreviousShortcut
            case .guiOpenEditorShortcut: return SettingsKey.guiOpenEditorShortcut
            case .guiOpenTerminalShortcut: return SettingsKey.guiOpenTerminalShortcut
            case .guiOpenFinderShortcut: return SettingsKey.guiOpenFinderShortcut
            case .guiOpenSettingsShortcut: return SettingsKey.guiOpenSettingsShortcut
            case .guiTooltipShortcut: return SettingsKey.guiTooltipShortcut
            }
        }

        var defaultSpec: String {
            switch self {
            case .guiHotkey: return SettingsKey.defaultGUIHotkey
            case .guiShowShortcut: return SettingsKey.defaultGUIShowShortcut
            case .guiAddProjectShortcut: return SettingsKey.defaultGUIAddProjectShortcut
            case .guiAddWorkspaceShortcut: return SettingsKey.defaultGUIAddWorkspaceShortcut
            case .guiReloadShortcut: return SettingsKey.defaultGUIReloadShortcut
            case .guiNextShortcut: return SettingsKey.defaultGUINextShortcut
            case .guiPreviousShortcut: return SettingsKey.defaultGUIPreviousShortcut
            case .guiOpenEditorShortcut: return SettingsKey.defaultGUIOpenEditorShortcut
            case .guiOpenTerminalShortcut: return SettingsKey.defaultGUIOpenTerminalShortcut
            case .guiOpenFinderShortcut: return SettingsKey.defaultGUIOpenFinderShortcut
            case .guiOpenSettingsShortcut: return SettingsKey.defaultGUIOpenSettingsShortcut
            case .guiTooltipShortcut: return SettingsKey.defaultGUITooltipShortcut
            }
        }

        init?(settingKey: String) {
            switch settingKey {
            case SettingsKey.guiHotkey: self = .guiHotkey
            case SettingsKey.guiShowShortcut: self = .guiShowShortcut
            case SettingsKey.guiAddProjectShortcut: self = .guiAddProjectShortcut
            case SettingsKey.guiAddWorkspaceShortcut: self = .guiAddWorkspaceShortcut
            case SettingsKey.guiReloadShortcut: self = .guiReloadShortcut
            case SettingsKey.guiNextShortcut: self = .guiNextShortcut
            case SettingsKey.guiPreviousShortcut: self = .guiPreviousShortcut
            case SettingsKey.guiOpenEditorShortcut: self = .guiOpenEditorShortcut
            case SettingsKey.guiOpenTerminalShortcut: self = .guiOpenTerminalShortcut
            case SettingsKey.guiOpenFinderShortcut: self = .guiOpenFinderShortcut
            case SettingsKey.guiOpenSettingsShortcut: self = .guiOpenSettingsShortcut
            case SettingsKey.guiTooltipShortcut: self = .guiTooltipShortcut
            default: return nil
            }
        }
    }
}
