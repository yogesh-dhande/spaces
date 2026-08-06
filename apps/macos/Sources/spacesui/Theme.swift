import AppKit
import spacesterminalcore

/// AppKit adapter over the active theme descriptor.
///
/// The token values live in `ThemeRegistry` (`spacesterminalcore`), which stays the single
/// source of truth shared with embedded Ghostty terminals; this type only converts the
/// descriptor's raw colors into appearance-dynamic `NSColor`s. Call sites keep referencing
/// `Theme.<token>`. The active descriptor is bound once at launch (see `ActiveTheme`), so
/// these static values never observe a mid-session theme change.
enum Theme {
    // MARK: Surfaces

    /// Window background.
    static let bg = dynamic(\.background)
    /// Section card background.
    static let surface = dynamic(\.surface)
    /// Secondary surface used inside cards (editing forms, stop script).
    static let surface2 = dynamic(\.surface2)
    /// Floating palette background — slightly darker than surface so selection tints read lighter.
    static let paletteSurface = dynamic(\.paletteSurface)
    /// Sidebar background.
    static let sidebarBg = dynamic(\.sidebarBackground)

    // MARK: Text

    static let text = dynamic(\.text)
    static let muted = dynamic(\.muted)
    static let mutedSecondary = dynamic(\.mutedSecondary)

    // MARK: Lines

    static let border = dynamic(\.border)
    static let borderStrong = dynamic(\.borderStrong)

    // MARK: Accent

    static let accent = dynamic(\.accent)
    static let accentStrong = dynamic(\.accentStrong)
    /// Fill color for accented backgrounds (filter chips, type-icon tile for
    /// browser/project, selected sidebar row, focus ring approximation).
    static let accentTint = dynamic(\.accentTint)
    /// Foreground text/symbols on top of `accentStrong` (primary buttons, badges).
    static let onAccent = dynamic(\.onAccent)

    /// Fill for primary action buttons — pairs with `primaryButtonText` in both appearances.
    static let primaryButtonFill = dynamic(\.primaryButtonFill)
    /// Ink text for primary action buttons — pairs with `primaryButtonFill`.
    static let primaryButtonText = dynamic(\.primaryButtonText)

    // MARK: Semantic status

    static let green = dynamic(\.green)
    static let red = dynamic(\.red)
    static let orange = dynamic(\.orange)

    // MARK: Row states

    /// Subtle background applied on hover.
    static let rowHover = dynamic(\.rowHover)
    /// Background for the selected sidebar row.
    static let rowSelected = dynamic(\.rowSelected)
    /// Muted selected-row tint for the command palette — same hue as rowSelected but lower alpha.
    static let rowSelectedCard = dynamic(\.rowSelectedCard)
    /// Subtle accent border for a selected palette row.
    static let rowSelectedCardBorder = dynamic(\.rowSelectedCardBorder)
    /// Neutral chip background (project chip, shortcut chip, branch chip).
    static let chipBg = dynamic(\.chipBackground)

    // MARK: Element pairs

    /// Type-icon tile for browser sessions: accent-tint fill over `accentStrong` glyph.
    static let iconBrowserBg = accentTint
    static let iconBrowserFg = accentStrong

    /// Type-icon tile for processes: green tint over green glyph.
    static let iconProcessBg = dynamic(\.iconProcessBackground)
    static let iconProcessFg = green

    /// Type-icon tile for coding agents: neutral ink tint over muted glyph.
    static let iconAgentBg = dynamic(\.iconAgentBackground)
    static let iconAgentFg = muted

    /// Type-icon tile for port definitions: orange tint over orange glyph.
    static let iconPortBg = dynamic(\.iconPortBackground)
    static let iconPortFg = orange

    /// Running status dot: solid green with an expanded halo.
    static let statusRunningFill = green
    static let statusRunningHalo = dynamic(\.statusRunningHalo)
    static let statusExitedStroke = statusFailed
    /// The one tint for a stopped runtime target, wherever it is reported: the sidebar's exited rows
    /// and offline/warning marks, the status dots, and the terminal pane's ended banner. Distinct
    /// from `red`, which is a truer red-orange reserved for attention marks that are not a stopped
    /// target (the alerts indicator).
    static let statusFailed = dynamic(\.statusFailed)
    static let statusIdleStroke = mutedSecondary
    static let statusWaitingFill = orange

    // MARK: Metrics

    /// Corner radius for the transparent "card" surfaces (workspace-detail sections, script editors).
    static let cardCornerRadius: CGFloat = 10

    /// Standard inset for a card's content row: 14 pt horizontal padding, 10 pt vertical.
    static let cardContentInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

    // MARK: Button styling

    /// Applies shared layout constraints so both button styles match in height and have
    /// consistent horizontal padding (≥12 pt per side) regardless of title length.
    @MainActor private static func applyButtonLayout(to button: NSButton, minimumWidth: CGFloat = 84) {
        button.translatesAutoresizingMaskIntoConstraints = false
        // Resist expansion so the NSView() spacer in form-footer stack views
        // always absorbs leftover width instead of the button.
        button.setContentHuggingPriority(.required, for: .horizontal)
        let titleWidth = button.attributedTitle.size().width
        let imageWidth = button.image?.size.width ?? 0
        let imageSpacing: CGFloat = button.image == nil || button.title.isEmpty ? 0 : 8
        let contentWidth = ceil(titleWidth + imageWidth + imageSpacing + 36)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 22),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: max(minimumWidth, contentWidth)),
        ])
    }

    /// Applies the design-system primary button style (accent fill, ink text).
    /// Call after setting `button.title` so `attributedTitle` picks up the correct string.
    ///
    /// Uses a layer background instead of `bezelColor` because on macOS 26, `bezelColor`
    /// takes full ownership of title rendering and ignores `contentTintColor`/`attributedTitle`.
    /// The fill and ink are the same in both appearances, so plain colors are safe on a layer.
    @MainActor static func applyPrimaryStyle(to button: NSButton) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = primaryButtonFill.cgColor
        button.layer?.cornerRadius = 5
        button.layer?.masksToBounds = true
        let fg = primaryButtonText
        button.contentTintColor = fg
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [.foregroundColor: fg, .font: Typography.primaryButtonLabel])
        applyButtonLayout(to: button, minimumWidth: 96)
    }

    /// Applies the design-system secondary button style (surface background, border, label text).
    /// Uses system semantic NSColors whose `.cgColor` is appearance-adaptive on macOS 14+.
    @MainActor static func applySecondaryStyle(to button: NSButton) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.masksToBounds = true
        button.layer?.borderWidth = 1
        bindAppearanceReactiveLayer(button) { view in
            view.layer?.backgroundColor = NSColor.controlColor.cgColor
            view.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        button.contentTintColor = .labelColor
        button.attributedTitle = NSAttributedString(
            string: button.title, attributes: [.foregroundColor: NSColor.labelColor, .font: Typography.secondaryButtonLabel])
        applyButtonLayout(to: button)
    }

    /// Applies a borderless text-button style for low-emphasis actions.
    @MainActor static func applyTextStyle(to button: NSButton, color: NSColor = .secondaryLabelColor) {
        button.isBordered = false
        button.wantsLayer = false
        button.layer = nil
        button.contentTintColor = color
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [.foregroundColor: color, .font: Typography.textButtonLabel])
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: Helpers

    private static func dynamic(_ token: KeyPath<ThemeAppearanceTokens, ThemeColor>) -> NSColor {
        NSColor(name: nil) { appearance in
            let descriptor = ActiveTheme.descriptor
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor((isDark ? descriptor.dark : descriptor.light)[keyPath: token])
        }
    }

    private static func nsColor(_ color: ThemeColor) -> NSColor {
        NSColor(
            srgbRed: CGFloat(color.red) / 255.0, green: CGFloat(color.green) / 255.0, blue: CGFloat(color.blue) / 255.0, alpha: CGFloat(color.alpha))
    }
}
