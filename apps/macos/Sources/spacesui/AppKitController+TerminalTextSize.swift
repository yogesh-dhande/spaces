import spacesclientcore
import spacesterminalcore

extension AppKitController {
    /// Loads the profile's persisted terminal text size at launch, before any pane exists, so every
    /// pane opened afterwards is built at it. A missing or unreadable setting resolves to the default.
    func loadStoredTerminalTextSize() {
        terminalPanes.terminalTextSize = TerminalTextSize(
            persistedRawValue: (try? SpacesClientDatabase.defaultDatabase().setting(key: ClientSettingsKey.terminalTextSize)) ?? nil)
    }

    /// Moves the app-wide terminal text size one zoom step and re-renders every open pane at it.
    /// Reached only from a focused terminal pane's zoom keys. A step that would leave the size's range
    /// resolves to the size already in use, so it persists nothing and repaints nothing: pressing zoom
    /// past either end does nothing at all.
    func adjustTerminalTextSize(_ command: TerminalTextZoomCommand) {
        let adjusted = terminalPanes.terminalTextSize.applying(command)
        guard adjusted != terminalPanes.terminalTextSize else { return }
        terminalPanes.terminalTextSize = adjusted
        try? SpacesClientDatabase.defaultDatabase().setSetting(key: ClientSettingsKey.terminalTextSize, value: adjusted.persistedRawValue)
        panelCoordinator.broadcastTerminalTextSize(adjusted)
    }
}
