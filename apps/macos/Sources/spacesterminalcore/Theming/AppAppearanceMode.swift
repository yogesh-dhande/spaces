/// The user's choice of app-wide UI appearance, independent of the terminal color theme.
///
/// `.system` follows the OS light/dark setting; `.light` and `.dark` force a variant.
/// Both the macOS and iOS apps default to `.dark` and persist the chosen mode's
/// `rawValue`, so the two platforms stay on one vocabulary. The SwiftUI/AppKit mapping
/// to a concrete appearance lives in each app, keeping this type free of UI dependencies.
public enum AppAppearanceMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// The appearance both apps launch with before the user changes it.
    public static let `default`: AppAppearanceMode = .dark

    /// Resolves a persisted raw value, falling back to the default for missing or
    /// unknown strings so an unreadable setting never leaves the app appearance unset.
    public init(persistedRawValue: String?) { self = persistedRawValue.flatMap(AppAppearanceMode.init(rawValue:)) ?? .default }

    /// Human-facing label for the settings picker.
    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
