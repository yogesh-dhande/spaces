import SwiftUI
import UIKit
import spacesterminalcore

/// UserDefaults key backing the `@AppStorage`-bound appearance selection. Distinct from the
/// connection settings blob so switching devices or clearing pairing never resets it.
enum AppAppearanceStorage {
    static let key = "spaces.mobile.appearance-mode"

    /// The appearance mode the app is currently persisting, for non-View callers (the terminal
    /// viewer model) that need it without an `@AppStorage` binding.
    static var current: AppAppearanceMode { AppAppearanceMode(persistedRawValue: UserDefaults.standard.string(forKey: key)) }
}

extension AppAppearanceMode {
    /// `nil` follows the system setting; the forced modes pin `.preferredColorScheme`.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The light/dark variant to send the daemon on terminal attach so it themes the session to
    /// match the app. `.system` resolves against the active screen trait, mirroring how the
    /// embedded mobile terminal picks its Ghostty color scheme.
    @MainActor var resolvedThemeAppearance: ThemeAppearance {
        switch self {
        case .system: return UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        }
    }
}
