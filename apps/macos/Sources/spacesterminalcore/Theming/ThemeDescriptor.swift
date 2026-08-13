import Foundation

/// Identifier for a theme in the registry (e.g. `spaces-brand`).
public struct ThemeID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

/// One sRGB color in a theme, as raw data so UI-free modules (this one) and both
/// platform UI layers (AppKit, SwiftUI) can share it.
public struct ThemeColor: Hashable, Sendable {
    public let red: Int
    public let green: Int
    public let blue: Int
    public let alpha: Double

    public init(_ red: Int, _ green: Int, _ blue: Int, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#rrggbb` form used by generated Ghostty config files (alpha is not representable there).
    public var hexRGB: String { String(format: "#%02x%02x%02x", red, green, blue) }

    /// `0x00RRGGBB` packed form used to hand colors to the C terminal shim (alpha is dropped).
    public var packedRGB: UInt32 { (UInt32(red & 0xFF) << 16) | (UInt32(green & 0xFF) << 8) | UInt32(blue & 0xFF) }
}

/// Terminal colors a theme exports to embedded Ghostty surfaces, one per appearance.
public struct GhosttyThemeExport: Hashable, Sendable {
    public let background: ThemeColor
    public let foreground: ThemeColor
    public let cursorColor: ThemeColor
    public let cursorText: ThemeColor
    public let selectionBackground: ThemeColor
    public let selectionForeground: ThemeColor
    /// The 16 ANSI palette entries, index 0-15.
    public let palette: [ThemeColor]

    public init(
        background: ThemeColor, foreground: ThemeColor, cursorColor: ThemeColor, cursorText: ThemeColor, selectionBackground: ThemeColor,
        selectionForeground: ThemeColor, palette: [ThemeColor]
    ) {
        precondition(palette.count == 16, "A Ghostty theme export needs exactly 16 palette entries")
        self.background = background
        self.foreground = foreground
        self.cursorColor = cursorColor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
    }
}

/// Semantic app colors for one appearance (light or dark). The AppKit and SwiftUI
/// adapters convert these into platform color types; this module stays UI-free.
public struct ThemeAppearanceTokens: Sendable {
    // Surfaces
    public let background: ThemeColor
    public let surface: ThemeColor
    public let surface2: ThemeColor
    public let paletteSurface: ThemeColor
    public let sidebarBackground: ThemeColor

    // Text
    public let text: ThemeColor
    public let muted: ThemeColor
    public let mutedSecondary: ThemeColor

    // Lines
    public let border: ThemeColor
    public let borderStrong: ThemeColor

    // Accent
    public let accent: ThemeColor
    public let accentStrong: ThemeColor
    public let accentTint: ThemeColor
    public let onAccent: ThemeColor
    public let primaryButtonFill: ThemeColor
    public let primaryButtonText: ThemeColor

    // Semantic status
    public let green: ThemeColor
    public let red: ThemeColor
    public let orange: ThemeColor
    public let blue: ThemeColor
    /// The "this stopped and you may care" tint for persistent stopped-pane chrome and other
    /// warning surfaces. Distinct from the operational sidebar's truer red-orange `red` token.
    public let statusFailed: ThemeColor

    // Row states
    public let rowHover: ThemeColor
    public let rowSelected: ThemeColor
    public let rowSelectedCard: ThemeColor
    public let rowSelectedCardBorder: ThemeColor
    public let chipBackground: ThemeColor

    // Element pairs (foregrounds reuse the tokens above)
    public let iconProcessBackground: ThemeColor
    public let iconAgentBackground: ThemeColor
    public let iconPortBackground: ThemeColor
    public let statusRunningHalo: ThemeColor

    // Terminal
    public let terminal: GhosttyThemeExport

    public init(
        background: ThemeColor, surface: ThemeColor, surface2: ThemeColor, paletteSurface: ThemeColor, sidebarBackground: ThemeColor,
        text: ThemeColor, muted: ThemeColor, mutedSecondary: ThemeColor, border: ThemeColor, borderStrong: ThemeColor, accent: ThemeColor,
        accentStrong: ThemeColor, accentTint: ThemeColor, onAccent: ThemeColor, primaryButtonFill: ThemeColor, primaryButtonText: ThemeColor,
        green: ThemeColor, red: ThemeColor, orange: ThemeColor, blue: ThemeColor, statusFailed: ThemeColor, rowHover: ThemeColor,
        rowSelected: ThemeColor, rowSelectedCard: ThemeColor, rowSelectedCardBorder: ThemeColor, chipBackground: ThemeColor,
        iconProcessBackground: ThemeColor, iconAgentBackground: ThemeColor, iconPortBackground: ThemeColor, statusRunningHalo: ThemeColor,
        terminal: GhosttyThemeExport
    ) {
        self.background = background
        self.surface = surface
        self.surface2 = surface2
        self.paletteSurface = paletteSurface
        self.sidebarBackground = sidebarBackground
        self.text = text
        self.muted = muted
        self.mutedSecondary = mutedSecondary
        self.border = border
        self.borderStrong = borderStrong
        self.accent = accent
        self.accentStrong = accentStrong
        self.accentTint = accentTint
        self.onAccent = onAccent
        self.primaryButtonFill = primaryButtonFill
        self.primaryButtonText = primaryButtonText
        self.green = green
        self.red = red
        self.orange = orange
        self.blue = blue
        self.statusFailed = statusFailed
        self.rowHover = rowHover
        self.rowSelected = rowSelected
        self.rowSelectedCard = rowSelectedCard
        self.rowSelectedCardBorder = rowSelectedCardBorder
        self.chipBackground = chipBackground
        self.iconProcessBackground = iconProcessBackground
        self.iconAgentBackground = iconAgentBackground
        self.iconPortBackground = iconPortBackground
        self.statusRunningHalo = statusRunningHalo
        self.terminal = terminal
    }
}

/// Which appearance variant of a theme to render, i.e. the OS light/dark mode. A client resolves
/// this from its own appearance and sends it to a remote daemon so the daemon's headless terminal
/// session renders with the matching variant (the daemon cannot read the client's OS appearance).
public enum ThemeAppearance: String, Codable, Sendable, Equatable {
    case light
    case dark
}

/// A complete theme: identity plus one token set per appearance.
public struct ThemeDescriptor: Sendable {
    public let id: ThemeID
    public let displayName: String
    public let light: ThemeAppearanceTokens
    public let dark: ThemeAppearanceTokens

    public init(id: ThemeID, displayName: String, light: ThemeAppearanceTokens, dark: ThemeAppearanceTokens) {
        self.id = id
        self.displayName = displayName
        self.light = light
        self.dark = dark
    }

    /// The terminal color export for the given appearance.
    public func terminal(for appearance: ThemeAppearance) -> GhosttyThemeExport {
        switch appearance {
        case .light: light.terminal
        case .dark: dark.terminal
        }
    }
}
