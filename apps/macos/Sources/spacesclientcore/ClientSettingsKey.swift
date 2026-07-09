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
    /// Records which coding agents Spaces has already auto-installed hooks for, per device, so
    /// auto-install runs once per (device, agent) and never fights a user who removes a hook. Stored
    /// as a JSON object `{ "<deviceID>": ["claudeCode", …] }`. Manual installs from settings bypass it.
    /// An agent is recorded only once its hooks are observed installed, so a failed attempt retries.
    public static let agentHooksAutoInstalled = "agent_hooks_auto_installed"
    /// The reason each coding agent's last hook install failed, per device, so Settings → Coding Agents
    /// can explain a "hooks not installed" row that auto-install already tried and could not fix (most
    /// often a `config.toml` that only the user can untangle). Stored as a JSON object
    /// `{ "<deviceID>": { "codex": "<message>" } }`. An agent's entry is cleared when it next installs.
    public static let agentHooksInstallFailures = "agent_hooks_install_failures"
}
