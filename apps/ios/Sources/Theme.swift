import SwiftUI
import UIKit
import spacesterminalcore

/// SwiftUI adapter over the active theme descriptor for the iOS app.
///
/// The token values live in `ThemeRegistry` (`spacesterminalcore`), the single source of
/// truth shared with the macOS GUI and embedded Ghostty terminals; this type only converts
/// the descriptor's raw colors into appearance-dynamic `Color`s so the iOS palette cannot
/// drift from the Mac/web palette. Call sites keep referencing `Theme.<token>`. The active
/// descriptor is bound once at launch (see `ActiveTheme`), so these static values never
/// observe a mid-session theme change.
enum Theme {
    // MARK: Surfaces

    /// App background.
    static let bg = dynamic(\.background)
    /// Section card background.
    static let surface = dynamic(\.surface)
    /// Secondary surface used inside cards (inputs, code-like content).
    static let surface2 = dynamic(\.surface2)

    // MARK: Text

    static let text = dynamic(\.text)
    static let muted = dynamic(\.muted)
    static let mutedSecondary = dynamic(\.mutedSecondary)

    // MARK: Lines

    static let border = dynamic(\.border)
    static let borderStrong = dynamic(\.borderStrong)

    // MARK: Accent (teal)

    static let accent = dynamic(\.accent)
    static let accentStrong = dynamic(\.accentStrong)
    /// Accent-tinted fill (selected rows, browser/agent tiles). Alpha differs per mode.
    static let accentTint = dynamic(\.accentTint)
    /// Fill for primary action buttons — bright teal in both appearances so dark ink reads.
    static let primaryButtonFill = dynamic(\.primaryButtonFill)
    /// Dark ink text for primary action buttons.
    static let primaryButtonText = dynamic(\.primaryButtonText)

    // MARK: Semantic status

    static let green = dynamic(\.green)
    static let red = dynamic(\.red)
    static let orange = dynamic(\.orange)
    static let blue = dynamic(\.blue)
    /// The one tint for a stopped runtime target, matching the Mac sidebar's exited rows. Distinct
    /// from `red`, which stays for attention marks that are not a stopped target.
    static let statusFailed = dynamic(\.statusFailed)

    // MARK: Chips & tiles

    /// Neutral chip background (shortcut, metadata chips).
    static let chipBg = dynamic(\.chipBackground)
    /// Running status dot halo.
    static let statusRunningHalo = dynamic(\.statusRunningHalo)

    // MARK: Helpers

    private static func dynamic(_ token: KeyPath<ThemeAppearanceTokens, ThemeColor>) -> Color {
        Color(
            uiColor: UIColor { traits in
                let descriptor = ActiveTheme.descriptor
                let isDark = traits.userInterfaceStyle == .dark
                return uiColor((isDark ? descriptor.dark : descriptor.light)[keyPath: token])
            })
    }

    private static func uiColor(_ color: ThemeColor) -> UIColor {
        UIColor(red: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: CGFloat(color.alpha))
    }
}
