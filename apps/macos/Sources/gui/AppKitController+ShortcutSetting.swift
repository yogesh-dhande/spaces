import Foundation
import streamctl

extension AppKitController {
    enum ShortcutSetting: CaseIterable {
        case guiHotkey
        case guiLeaderHotkey
        case guiShowShortcut
        case guiDashboardShortcut
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
        case guiWindowShortcut
        case guiWindowSequenceShortcut

        var label: String {
            switch self {
            case .guiHotkey: return "Toggle app"
            case .guiLeaderHotkey: return "Shortcut leader"
            case .guiShowShortcut: return "Focus selected workspace"
            case .guiDashboardShortcut: return "Show dashboard"
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
            case .guiWindowShortcut: return "Focus window 1-9"
            case .guiWindowSequenceShortcut: return "Queue windows 1-9"
            }
        }

        static let settingsPanelCases: [ShortcutSetting] = [
            .guiLeaderHotkey, .guiHotkey, .guiNextShortcut, .guiPreviousShortcut, .guiTooltipShortcut, .guiOpenEditorShortcut,
            .guiDashboardShortcut, .guiShowShortcut,
            .guiAddProjectShortcut, .guiAddWorkspaceShortcut, .guiReloadShortcut, .guiOpenTerminalShortcut, .guiOpenFinderShortcut,
            .guiOpenSettingsShortcut, .guiWindowShortcut, .guiWindowSequenceShortcut,
        ]

        var usesLeader: Bool {
            switch self {
            case .guiDashboardShortcut, .guiNextShortcut, .guiPreviousShortcut, .guiOpenEditorShortcut, .guiOpenFinderShortcut, .guiTooltipShortcut,
                .guiReloadShortcut, .guiWindowSequenceShortcut:
                return true
            default:
                return false
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
            case .guiWindowShortcut, .guiWindowSequenceShortcut: return true
            default: return false
            }
        }

        var settingKey: String {
            switch self {
            case .guiHotkey: return SettingsKey.guiHotkey
            case .guiLeaderHotkey: return SettingsKey.guiLeaderHotkey
            case .guiShowShortcut: return SettingsKey.guiShowShortcut
            case .guiDashboardShortcut: return SettingsKey.guiDashboardShortcut
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
            case .guiWindowShortcut: return SettingsKey.guiWindowShortcut
            case .guiWindowSequenceShortcut: return SettingsKey.guiWindowSequenceShortcut
            }
        }

        var defaultSpec: String {
            switch self {
            case .guiHotkey: return SettingsKey.defaultGUIHotkey
            case .guiLeaderHotkey: return SettingsKey.defaultGUILeaderHotkey
            case .guiShowShortcut: return SettingsKey.defaultGUIShowShortcut
            case .guiDashboardShortcut: return SettingsKey.defaultGUIDashboardShortcut
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
            case .guiWindowShortcut: return SettingsKey.defaultGUIWindowShortcut
            case .guiWindowSequenceShortcut: return SettingsKey.defaultGUIWindowSequenceShortcut
            }
        }

        init?(settingKey: String) {
            switch settingKey {
            case SettingsKey.guiHotkey: self = .guiHotkey
            case SettingsKey.guiLeaderHotkey: self = .guiLeaderHotkey
            case SettingsKey.guiShowShortcut: self = .guiShowShortcut
            case SettingsKey.guiDashboardShortcut: self = .guiDashboardShortcut
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
            case SettingsKey.guiWindowShortcut: self = .guiWindowShortcut
            case SettingsKey.guiWindowSequenceShortcut: self = .guiWindowSequenceShortcut
            default: return nil
            }
        }
    }
}
