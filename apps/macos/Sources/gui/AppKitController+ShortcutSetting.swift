import Foundation
import streamctl

extension AppKitController {
    enum ShortcutSetting: CaseIterable {
        case guiHotkey
        case guiNextShortcut
        case guiPreviousShortcut
        case guiShowShortcut
        case guiAddProjectShortcut
        case guiAddWorkspaceShortcut
        case guiReloadShortcut
        case guiOpenEditorShortcut
        case guiOpenTerminalShortcut
        case guiOpenFinderShortcut
        case guiOpenSettingsShortcut
        case guiTooltipShortcut

        var label: String {
            switch self {
            case .guiHotkey: return "Toggle app"
            case .guiNextShortcut: return "Next workspace/window"
            case .guiPreviousShortcut: return "Previous workspace/window"
            case .guiShowShortcut: return "Activate selected workspace"
            case .guiAddProjectShortcut: return "New project"
            case .guiAddWorkspaceShortcut: return "New workspace"
            case .guiReloadShortcut: return "Reload data"
            case .guiOpenEditorShortcut: return "Open editor"
            case .guiOpenTerminalShortcut: return "Open terminal"
            case .guiOpenFinderShortcut: return "Open Finder"
            case .guiOpenSettingsShortcut: return "Open settings"
            case .guiTooltipShortcut: return "Toggle tooltip"
            }
        }

        static let settingsPanelCases: [ShortcutSetting] = [
            .guiHotkey, .guiNextShortcut, .guiPreviousShortcut, .guiShowShortcut, .guiOpenEditorShortcut, .guiOpenTerminalShortcut,
            .guiOpenFinderShortcut, .guiTooltipShortcut,
        ]

        var settingKey: String {
            switch self {
            case .guiHotkey: return SettingsKey.guiHotkey
            case .guiNextShortcut: return SettingsKey.guiNextShortcut
            case .guiPreviousShortcut: return SettingsKey.guiPreviousShortcut
            case .guiShowShortcut: return SettingsKey.guiShowShortcut
            case .guiAddProjectShortcut: return SettingsKey.guiAddProjectShortcut
            case .guiAddWorkspaceShortcut: return SettingsKey.guiAddWorkspaceShortcut
            case .guiReloadShortcut: return SettingsKey.guiReloadShortcut
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
            case .guiNextShortcut: return SettingsKey.defaultGUINextShortcut
            case .guiPreviousShortcut: return SettingsKey.defaultGUIPreviousShortcut
            case .guiShowShortcut: return SettingsKey.defaultGUIShowShortcut
            case .guiAddProjectShortcut: return SettingsKey.defaultGUIAddProjectShortcut
            case .guiAddWorkspaceShortcut: return SettingsKey.defaultGUIAddWorkspaceShortcut
            case .guiReloadShortcut: return SettingsKey.defaultGUIReloadShortcut
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
            case SettingsKey.guiNextShortcut: self = .guiNextShortcut
            case SettingsKey.guiPreviousShortcut: self = .guiPreviousShortcut
            case SettingsKey.guiShowShortcut: self = .guiShowShortcut
            case SettingsKey.guiAddProjectShortcut: self = .guiAddProjectShortcut
            case SettingsKey.guiAddWorkspaceShortcut: self = .guiAddWorkspaceShortcut
            case SettingsKey.guiReloadShortcut: self = .guiReloadShortcut
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
