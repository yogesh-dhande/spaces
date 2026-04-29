import AppKit

/// Spaces brand tokens for the AppKit GUI.
///
/// Values mirror `apps/web/app/globals.css` and
/// `design-mocks/workspace-detail/shared.css` one-for-one so the mocks remain
/// the source of truth. When adding a new token, add it to `shared.css` first
/// and then encode it here.
enum Theme {
    // MARK: Surfaces

    /// Window background.
    static let bg = dynamic(light: (248, 247, 241), dark: (15, 21, 23))
    /// Section card background.
    static let surface = dynamic(light: (255, 255, 255), dark: (29, 42, 45))
    /// Secondary surface used inside cards (editing forms, stop script).
    static let surface2 = dynamic(light: (241, 239, 230), dark: (23, 33, 36))
    /// Sidebar background (matches `--sidebar-bg`).
    static let sidebarBg = dynamic(light: (241, 239, 230), dark: (15, 21, 23))

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
    /// Fill color for accented backgrounds (filter chips, type-icon tile for
    /// browser/project, selected sidebar row, focus ring approximation).
    /// Alpha differs per mode: 0.12 light, 0.16 dark — same as CSS.
    static let accentTint = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? color(89, 219, 205, alpha: 0.16) : color(15, 122, 118, alpha: 0.12)
    }
    /// Foreground text/symbols on top of `accentStrong` (primary buttons, badges).
    /// White in light, dark ink in dark — ensures WCAG contrast in both modes.
    static let onAccent = dynamic(light: (255, 255, 255), dark: (15, 21, 23))

    /// Fill for primary action buttons — uses the bright teal in both appearances so
    /// dark ink text is always readable (mirrors the mock's dark-mode button style).
    static let primaryButtonFill = dynamic(light: (61, 198, 184), dark: (61, 198, 184))
    /// Dark ink text for primary action buttons — pairs with `primaryButtonFill`.
    static let primaryButtonText = dynamic(light: (15, 21, 23), dark: (15, 21, 23))

    // MARK: Semantic status

    static let green = dynamic(light: (58, 158, 95), dark: (76, 208, 122))
    static let red = dynamic(light: (198, 58, 47), dark: (255, 107, 96))
    static let orange = dynamic(light: (208, 122, 26), dark: (245, 167, 66))

    // MARK: Row states

    /// Subtle background applied on hover.
    static let rowHover = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? color(234, 240, 239, alpha: 0.06) : color(15, 32, 40, alpha: 0.04)
    }
    /// Background for the selected sidebar row.
    static let rowSelected = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? color(89, 219, 205, alpha: 0.18) : color(15, 122, 118, alpha: 0.14)
    }
    /// Neutral chip background (project chip, shortcut chip, branch chip).
    static let chipBg = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? color(234, 240, 239, alpha: 0.08) : color(15, 32, 40, alpha: 0.06)
    }

    // MARK: Element pairs

    /// Type-icon tile for browser sessions: accent-tint fill over `accentStrong` glyph.
    static let iconBrowserBg = accentTint
    static let iconBrowserFg = accentStrong

    /// Type-icon tile for processes: green at 0.16 alpha over green glyph.
    /// Alpha stays constant across modes so it tracks `green` automatically.
    static let iconProcessBg = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? color(76, 208, 122, alpha: 0.16) : color(58, 158, 95, alpha: 0.16)
    }
    static let iconProcessFg = green

    /// Type-icon tile for coding agents: neutral ink tint over muted glyph.
    static let iconAgentBg = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? color(234, 240, 239, alpha: 0.10) : color(15, 32, 40, alpha: 0.08)
    }
    static let iconAgentFg = muted

    /// Type-icon tile for port definitions: orange tint over orange glyph.
    static let iconPortBg = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? color(245, 167, 66, alpha: 0.14) : color(208, 122, 26, alpha: 0.12)
    }
    static let iconPortFg = orange

    /// Running status dot: solid green with an expanded halo at 0.22 alpha.
    static let statusRunningFill = green
    static let statusRunningHalo = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? color(76, 208, 122, alpha: 0.22) : color(58, 158, 95, alpha: 0.22)
    }
    static let statusExitedStroke = red
    static let statusIdleStroke = mutedSecondary
    static let statusWaitingFill = orange

    // MARK: Button styling

    /// Applies shared layout constraints so both button styles match in height and have
    /// consistent horizontal padding (≥12 pt per side) regardless of title length.
    @MainActor private static func applyButtonLayout(to button: NSButton) {
        button.translatesAutoresizingMaskIntoConstraints = false
        // Resist expansion so the NSView() spacer in form-footer stack views
        // always absorbs leftover width instead of the button.
        button.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 22), button.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
    }

    /// Applies the design-system primary button style (bright-teal fill, dark ink text).
    /// Call after setting `button.title` so `attributedTitle` picks up the correct string.
    ///
    /// Uses a layer background instead of `bezelColor` because on macOS 26, `bezelColor`
    /// takes full ownership of title rendering and ignores `contentTintColor`/`attributedTitle`.
    @MainActor static func applyPrimaryStyle(to button: NSButton) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = CGColor(srgbRed: 61 / 255, green: 198 / 255, blue: 184 / 255, alpha: 1)
        button.layer?.cornerRadius = 5
        button.layer?.masksToBounds = true
        let fg = NSColor(srgbRed: 15 / 255, green: 21 / 255, blue: 23 / 255, alpha: 1)
        button.contentTintColor = fg
        button.attributedTitle = NSAttributedString(
            string: button.title, attributes: [.foregroundColor: fg, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        applyButtonLayout(to: button)
    }

    /// Applies the design-system secondary button style (surface background, border, label text).
    /// Uses system semantic NSColors whose `.cgColor` is appearance-adaptive on macOS 14+.
    @MainActor static func applySecondaryStyle(to button: NSButton) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.controlColor.cgColor
        button.layer?.cornerRadius = 5
        button.layer?.masksToBounds = true
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.separatorColor.cgColor
        button.contentTintColor = .labelColor
        button.attributedTitle = NSAttributedString(
            string: button.title, attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 13)])
        applyButtonLayout(to: button)
    }

    /// Applies a borderless text-button style for low-emphasis actions.
    @MainActor static func applyTextStyle(to button: NSButton, color: NSColor = .secondaryLabelColor) {
        button.isBordered = false
        button.wantsLayer = false
        button.layer = nil
        button.contentTintColor = color
        button.attributedTitle = NSAttributedString(
            string: button.title, attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: Helpers

    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int), alpha: CGFloat = 1.0) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return color(rgb.0, rgb.1, rgb.2, alpha: alpha)
        }
    }

    private static func color(_ r: Int, _ g: Int, _ b: Int, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: alpha)
    }
}
