import AppKit
import Testing

@testable import spacesui

@MainActor @Suite struct ThemeTests {
    /// The tokens hard-code values from `design-mocks/workspace-detail/shared.css`.
    /// When this test fails, either shared.css moved or the wrong values got
    /// copied in — fix Theme.swift to match the stylesheet, not the test.
    @Test func lightModeResolvesToBrandTokens() {
        let light = NSAppearance(named: .aqua)!

        expect(Theme.bg, matches: (248, 247, 241), under: light)
        expect(Theme.surface, matches: (255, 255, 255), under: light)
        expect(Theme.text, matches: (16, 32, 40), under: light)
        expect(Theme.muted, matches: (58, 77, 87), under: light)
        expect(Theme.border, matches: (213, 216, 211), under: light)
        expect(Theme.accent, matches: (15, 122, 118), under: light)
        expect(Theme.accentStrong, matches: (13, 95, 93), under: light)
        expect(Theme.onAccent, matches: (255, 255, 255), under: light)
        expect(Theme.green, matches: (58, 158, 95), under: light)
        expect(Theme.red, matches: (198, 58, 47), under: light)
        expect(Theme.orange, matches: (208, 122, 26), under: light)
    }

    @Test func darkModeResolvesToBrandTokens() {
        let dark = NSAppearance(named: .darkAqua)!

        expect(Theme.bg, matches: (15, 21, 23), under: dark)
        expect(Theme.surface, matches: (29, 42, 45), under: dark)
        expect(Theme.text, matches: (234, 240, 239), under: dark)
        expect(Theme.muted, matches: (173, 192, 196), under: dark)
        expect(Theme.border, matches: (48, 67, 70), under: dark)
        expect(Theme.accent, matches: (89, 219, 205), under: dark)
        expect(Theme.accentStrong, matches: (61, 198, 184), under: dark)
        expect(Theme.onAccent, matches: (15, 21, 23), under: dark)
        expect(Theme.green, matches: (76, 208, 122), under: dark)
        expect(Theme.red, matches: (255, 107, 96), under: dark)
        expect(Theme.orange, matches: (245, 167, 66), under: dark)
    }

    @Test func accentTintUsesDifferentAlphasPerMode() {
        // CSS spec: rgba(15,122,118,0.12) light / rgba(89,219,205,0.16) dark.
        let light = resolvedSRGB(Theme.accentTint, under: NSAppearance(named: .aqua)!)
        #expect(abs(light.alpha - 0.12) < 0.01)

        let dark = resolvedSRGB(Theme.accentTint, under: NSAppearance(named: .darkAqua)!)
        #expect(abs(dark.alpha - 0.16) < 0.01)
    }

    @Test func onAccentPairsWithAccentStrongForReadableContrast() {
        // Light: white on dark-teal accentStrong (≈13, 95, 93) — high contrast.
        // Dark: dark ink (≈15, 21, 23) on mid-teal accentStrong (≈61, 198, 184).
        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!

        #expect(contrastRatio(Theme.onAccent, Theme.accentStrong, under: light) >= 4.5)
        #expect(contrastRatio(Theme.onAccent, Theme.accentStrong, under: dark) >= 4.5)
    }

    // MARK: Helpers

    private func expect(
        _ color: NSColor, matches expected: (Int, Int, Int), under appearance: NSAppearance, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let resolved = resolvedSRGB(color, under: appearance)
        let r = Int((resolved.red * 255).rounded())
        let g = Int((resolved.green * 255).rounded())
        let b = Int((resolved.blue * 255).rounded())
        #expect((r, g, b) == expected, "got (\(r), \(g), \(b)), expected \(expected)", sourceLocation: sourceLocation)
    }

    private struct RGBA {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    private func resolvedSRGB(_ color: NSColor, under appearance: NSAppearance) -> RGBA {
        var rgba = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
        appearance.performAsCurrentDrawingAppearance {
            let srgb = color.usingColorSpace(.sRGB) ?? color
            rgba = RGBA(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
        }
        return rgba
    }

    /// WCAG contrast ratio between two colors resolved under a given appearance.
    private func contrastRatio(_ a: NSColor, _ b: NSColor, under appearance: NSAppearance) -> Double {
        let la = relativeLuminance(resolvedSRGB(a, under: appearance))
        let lb = relativeLuminance(resolvedSRGB(b, under: appearance))
        let (lighter, darker) = la > lb ? (la, lb) : (lb, la)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ c: RGBA) -> Double {
        func channel(_ v: CGFloat) -> Double {
            let x = Double(v)
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
    }
}
