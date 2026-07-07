import SwiftUI
import spacesterminalcore

/// UserDefaults key backing the `@AppStorage`-bound appearance selection. Distinct from the
/// connection settings blob so switching devices or clearing pairing never resets it.
enum AppAppearanceStorage {
    static let key = "spaces.mobile.appearance-mode"
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
}
