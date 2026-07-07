import AppKit
import spacesclientcore
import spacesterminalcore
import workspacecore

extension AppKitController {
    /// Reads the persisted app-wide appearance mode and applies it to the running app.
    /// Called once at launch and again whenever the General settings picker changes it.
    /// A missing or unreadable setting resolves to the dark default.
    func applyStoredAppAppearance() {
        let stored = (try? SpacesClientDatabase.defaultDatabase().setting(key: SettingsKey.appAppearanceMode)) ?? nil
        applyAppAppearance(AppAppearanceMode(persistedRawValue: stored))
    }

    /// The persisted appearance mode, resolving a missing value to the dark default.
    /// Backs the General settings picker's current selection.
    func storedAppAppearanceMode() -> AppAppearanceMode {
        let stored = (try? SpacesClientDatabase.defaultDatabase().setting(key: SettingsKey.appAppearanceMode)) ?? nil
        return AppAppearanceMode(persistedRawValue: stored)
    }

    /// Overrides `NSApp.appearance` so every window, the menu, and the embedded terminals'
    /// `effectiveAppearance`-derived light/dark variant follow one chosen mode. Views drawn with
    /// dynamic `NSColor`s recolor automatically; the notification lets layer-backed `CGColor`
    /// chrome (see `bindAppearanceReactiveLayer`) re-resolve its snapshot to the new variant.
    func applyAppAppearance(_ mode: AppAppearanceMode) {
        NSApp?.appearance = mode.nsAppearance
        NotificationCenter.default.post(name: .spacesAppAppearanceDidChange, object: nil)
    }
}

extension AppAppearanceMode {
    /// `nil` lets the app follow the OS setting; the forced modes pin a concrete variant.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
