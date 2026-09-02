import Foundation

public enum ClientSettingsKey {
    public static let appEditor = "app_editor"
    public static let guiHotkey = "gui_hotkey"
    public static let defaultGUIHotkey = "cmd+alt+="
    public static let guiCommandPaletteHotkey = "gui_command_palette_hotkey"
    public static let defaultGUICommandPaletteHotkey = "cmd+alt+minus"
    public static let guiLeaderHotkey = "gui_leader_hotkey"
    public static let defaultGUILeaderHotkey = "cmd+alt"
    public static let guiAlertsShortcut = "gui_alerts_shortcut"
    public static let defaultGUIAlertsShortcut = "a"
    public static let guiAddWorkspaceShortcut = "gui_add_workspace_shortcut"
    public static let defaultGUIAddWorkspaceShortcut = "cmd+n"
    public static let guiReloadShortcut = "gui_reload_shortcut"
    public static let defaultGUIReloadShortcut = "r"
    public static let guiOpenEditorShortcut = "gui_open_editor_shortcut"
    public static let defaultGUIOpenEditorShortcut = "e"
    public static let guiOpenTerminalShortcut = "gui_open_terminal_shortcut"
    public static let defaultGUIOpenTerminalShortcut = "t"
    public static let guiNewTabShortcut = "gui_new_tab_shortcut"
    public static let defaultGUINewTabShortcut = "cmd+t"
    public static let guiOpenFinderShortcut = "gui_open_finder_shortcut"
    public static let defaultGUIOpenFinderShortcut = "f"
    public static let guiOpenSettingsShortcut = "gui_open_settings_shortcut"
    public static let defaultGUIOpenSettingsShortcut = "cmd+,"
    public static let guiNextShortcut = "gui_next_shortcut"
    public static let defaultGUINextShortcut = "]"
    public static let guiPreviousShortcut = "gui_previous_shortcut"
    public static let defaultGUIPreviousShortcut = "["
    public static let guiSidebarNextShortcut = "gui_sidebar_next_shortcut"
    public static let defaultGUISidebarNextShortcut = "down"
    public static let guiSidebarPreviousShortcut = "gui_sidebar_previous_shortcut"
    public static let defaultGUISidebarPreviousShortcut = "up"
    public static let guiWindowShortcut = "gui_window_shortcut"
    public static let defaultGUIWindowShortcut = "cmd+1"
    public static let alertsDismissedAttentionItems = "alerts_dismissed_attention_items"
    public static let activeWorkspaceID = "active_workspace_id"
    /// Client-side theme selection (a `ThemeID` raw value). Internal-only: persisted and
    /// honored at launch, but not exposed through any settings UI or CLI yet.
    public static let appThemeID = "app_theme_id"
    /// App-wide UI appearance (an `AppAppearanceMode` raw value: `system`/`light`/`dark`).
    /// An unset value resolves to the dark default.
    public static let appAppearanceMode = "app_appearance_mode"
    /// App-wide terminal text size in points (a `TerminalTextSize` persisted raw value), moved by the
    /// terminal zoom keys. An unset value resolves to the 12 pt default.
    public static let terminalTextSize = "terminal_text_size"
    /// Whether the app updates from the pre-release Sparkle feed ("1") instead of the stable feed.
    /// An unset value resolves to off, so an install only sees promoted releases until the user opts in.
    public static let appPrereleaseUpdates = "app_prerelease_updates"
    /// The `AgentHookCommand.hookVersion` the user last dismissed the launch coding-agents setup step
    /// for, as a decimal string. The step reappears only when a Spaces release bumps the hook version,
    /// so skipping it is respected until the hooks Spaces wants to write actually change.
    public static let agentHooksSetupDismissedVersion = "agent_hooks_setup_dismissed_version"
}
