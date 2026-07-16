import SwiftUI
import UIKit

/// Spaces brand tokens for the iOS app.
///
/// Values mirror `apps/macos/Sources/spacesui/Theme.swift` one-for-one so the
/// macOS GUI and `apps/web/app/globals.css` remain the single source of truth.
/// When a token changes there, update it here too. Each token is a dynamic
/// `Color` that resolves to its light or dark RGB based on the active trait
/// collection.
enum Theme {
    // MARK: Surfaces

    /// App background.
    static let bg = dynamic(light: (248, 247, 241), dark: (15, 21, 23))
    /// Section card background.
    static let surface = dynamic(light: (255, 255, 255), dark: (29, 42, 45))
    /// Secondary surface used inside cards (inputs, code-like content).
    static let surface2 = dynamic(light: (241, 239, 230), dark: (23, 33, 36))

    // MARK: Text

    static let text = dynamic(light: (16, 32, 40), dark: (234, 240, 239))
    static let muted = dynamic(light: (58, 77, 87), dark: (173, 192, 196))
    static let mutedSecondary = dynamic(light: (111, 132, 141), dark: (122, 138, 141))

    // MARK: Lines

    static let border = dynamic(light: (213, 216, 211), dark: (48, 67, 70))
    static let borderStrong = dynamic(light: (184, 189, 181), dark: (63, 84, 88))

    // MARK: Accent (teal)

    static let accent = dynamic(light: (15, 122, 118), dark: (89, 219, 205))
    static let accentStrong = dynamic(light: (13, 95, 93), dark: (61, 198, 184))
    /// Accent-tinted fill (selected rows, browser/agent tiles). Alpha differs per mode.
    static let accentTint = dynamic(light: (15, 122, 118), dark: (89, 219, 205), lightAlpha: 0.12, darkAlpha: 0.16)
    /// Fill for primary action buttons — bright teal in both appearances so dark ink reads.
    static let primaryButtonFill = dynamic(light: (61, 198, 184), dark: (61, 198, 184))
    /// Dark ink text for primary action buttons.
    static let primaryButtonText = dynamic(light: (15, 21, 23), dark: (15, 21, 23))

    // MARK: Semantic status

    static let green = dynamic(light: (58, 158, 95), dark: (76, 208, 122))
    static let red = dynamic(light: (198, 58, 47), dark: (255, 107, 96))
    static let orange = dynamic(light: (208, 122, 26), dark: (245, 167, 66))
    /// The one tint for a stopped runtime target, matching the Mac sidebar's exited rows. Distinct
    /// from `red`, which stays for attention marks that are not a stopped target.
    static let statusFailed = dynamic(light: (186, 67, 111), dark: (255, 111, 91), lightAlpha: 0.95, darkAlpha: 0.95)

    // MARK: Chips & tiles

    /// Neutral chip background (shortcut, metadata chips).
    static let chipBg = dynamic(light: (15, 32, 40), dark: (234, 240, 239), lightAlpha: 0.06, darkAlpha: 0.08)
    /// Running status dot halo.
    static let statusRunningHalo = dynamic(light: (58, 158, 95), dark: (76, 208, 122), lightAlpha: 0.22, darkAlpha: 0.22)

    // MARK: Helpers

    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int), lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(
            uiColor: UIColor { traits in
                let isDark = traits.userInterfaceStyle == .dark
                let rgb = isDark ? dark : light
                let alpha = isDark ? darkAlpha : lightAlpha
                return UIColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: alpha)
            })
    }
}
