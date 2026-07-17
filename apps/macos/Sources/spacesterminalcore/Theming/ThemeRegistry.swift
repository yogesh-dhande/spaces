import Foundation

/// The built-in themes and the resolution rule for the active one. `spaces-brand` is the
/// only shipped theme; selection stays internal (no picker, CLI, or public docs) until the
/// model has proven out, so resolution simply falls back to the default for unknown ids.
public enum ThemeRegistry {
    public static let defaultThemeID = ThemeID(rawValue: "spaces-brand")

    public static let themes: [ThemeDescriptor] = [spacesBrand]

    /// Resolves a stored theme id to a descriptor; a missing or unknown id is the default theme.
    public static func descriptor(id: ThemeID?) -> ThemeDescriptor { themes.first { $0.id == id } ?? spacesBrand }

    /// The Spaces brand theme. App token values mirror `apps/web/app/globals.css` and
    /// `design-mocks/workspace-detail/shared.css` one-for-one so the mocks remain the source
    /// of truth; terminal colors are derived from the same family (the dark terminal
    /// background is the dark sidebar background) so embedded terminals blend into the shell.
    public static let spacesBrand = ThemeDescriptor(id: defaultThemeID, displayName: "Spaces", light: spacesBrandLight, dark: spacesBrandDark)

    private static let spacesBrandLightTerminal = GhosttyThemeExport(
        background: ThemeColor(248, 247, 241), foreground: ThemeColor(16, 32, 40), cursorColor: ThemeColor(15, 122, 118),
        cursorText: ThemeColor(255, 255, 255), selectionBackground: ThemeColor(198, 226, 222), selectionForeground: ThemeColor(16, 32, 40),
        palette: [
            ThemeColor(16, 32, 40), ThemeColor(198, 58, 47), ThemeColor(58, 158, 95), ThemeColor(208, 122, 26), ThemeColor(52, 101, 164),
            ThemeColor(136, 84, 160), ThemeColor(15, 122, 118), ThemeColor(111, 132, 141), ThemeColor(58, 77, 87), ThemeColor(224, 82, 70),
            ThemeColor(72, 180, 112), ThemeColor(226, 140, 42), ThemeColor(66, 120, 190), ThemeColor(156, 100, 180), ThemeColor(13, 95, 93),
            ThemeColor(248, 247, 241),
        ])

    private static let spacesBrandDarkTerminal = GhosttyThemeExport(
        background: ThemeColor(15, 21, 23), foreground: ThemeColor(234, 240, 239), cursorColor: ThemeColor(89, 219, 205),
        cursorText: ThemeColor(15, 21, 23), selectionBackground: ThemeColor(44, 84, 80), selectionForeground: ThemeColor(234, 240, 239),
        palette: [
            ThemeColor(23, 33, 36), ThemeColor(255, 107, 96), ThemeColor(76, 208, 122), ThemeColor(245, 167, 66), ThemeColor(122, 162, 210),
            ThemeColor(187, 128, 204), ThemeColor(89, 219, 205), ThemeColor(173, 192, 196), ThemeColor(63, 84, 88), ThemeColor(255, 138, 128),
            ThemeColor(106, 224, 146), ThemeColor(250, 190, 102), ThemeColor(150, 185, 225), ThemeColor(210, 150, 222), ThemeColor(121, 230, 219),
            ThemeColor(234, 240, 239),
        ])

    private static let spacesBrandLight = ThemeAppearanceTokens(
        background: ThemeColor(248, 247, 241), surface: ThemeColor(255, 255, 255), surface2: ThemeColor(241, 239, 230),
        paletteSurface: ThemeColor(250, 249, 244), sidebarBackground: ThemeColor(241, 239, 230), text: ThemeColor(16, 32, 40),
        muted: ThemeColor(58, 77, 87), mutedSecondary: ThemeColor(111, 132, 141), border: ThemeColor(213, 216, 211),
        borderStrong: ThemeColor(184, 189, 181), accent: ThemeColor(15, 122, 118), accentStrong: ThemeColor(13, 95, 93),
        accentTint: ThemeColor(15, 122, 118, alpha: 0.12), onAccent: ThemeColor(255, 255, 255), primaryButtonFill: ThemeColor(61, 198, 184),
        primaryButtonText: ThemeColor(15, 21, 23), green: ThemeColor(58, 158, 95), red: ThemeColor(198, 58, 47), orange: ThemeColor(208, 122, 26),
        statusFailed: ThemeColor(186, 67, 111, alpha: 0.95), rowHover: ThemeColor(15, 32, 40, alpha: 0.04),
        rowSelected: ThemeColor(15, 122, 118, alpha: 0.14),
        rowSelectedCard: ThemeColor(15, 122, 118, alpha: 0.07), rowSelectedCardBorder: ThemeColor(13, 95, 93, alpha: 0.28),
        chipBackground: ThemeColor(15, 32, 40, alpha: 0.06), iconProcessBackground: ThemeColor(58, 158, 95, alpha: 0.16),
        iconAgentBackground: ThemeColor(15, 32, 40, alpha: 0.08), iconPortBackground: ThemeColor(208, 122, 26, alpha: 0.12),
        statusRunningHalo: ThemeColor(58, 158, 95, alpha: 0.22), terminal: spacesBrandLightTerminal)

    private static let spacesBrandDark = ThemeAppearanceTokens(
        background: ThemeColor(15, 21, 23), surface: ThemeColor(29, 42, 45), surface2: ThemeColor(23, 33, 36), paletteSurface: ThemeColor(25, 37, 40),
        sidebarBackground: ThemeColor(15, 21, 23), text: ThemeColor(234, 240, 239), muted: ThemeColor(173, 192, 196),
        mutedSecondary: ThemeColor(122, 138, 141), border: ThemeColor(48, 67, 70), borderStrong: ThemeColor(63, 84, 88),
        accent: ThemeColor(89, 219, 205), accentStrong: ThemeColor(61, 198, 184), accentTint: ThemeColor(89, 219, 205, alpha: 0.16),
        onAccent: ThemeColor(15, 21, 23), primaryButtonFill: ThemeColor(61, 198, 184), primaryButtonText: ThemeColor(15, 21, 23),
        green: ThemeColor(76, 208, 122), red: ThemeColor(255, 107, 96), orange: ThemeColor(245, 167, 66),
        statusFailed: ThemeColor(255, 111, 91, alpha: 0.95), rowHover: ThemeColor(234, 240, 239, alpha: 0.06),
        rowSelected: ThemeColor(89, 219, 205, alpha: 0.18),
        rowSelectedCard: ThemeColor(89, 219, 205, alpha: 0.07), rowSelectedCardBorder: ThemeColor(61, 198, 184, alpha: 0.28),
        chipBackground: ThemeColor(234, 240, 239, alpha: 0.08), iconProcessBackground: ThemeColor(76, 208, 122, alpha: 0.16),
        iconAgentBackground: ThemeColor(234, 240, 239, alpha: 0.10), iconPortBackground: ThemeColor(245, 167, 66, alpha: 0.14),
        statusRunningHalo: ThemeColor(76, 208, 122, alpha: 0.22), terminal: spacesBrandDarkTerminal)
}

/// The process-wide active theme. The GUI resolves the stored theme id once at launch and
/// binds it here before any terminal starts; processes that never bind (daemon, CLI) resolve
/// to the default theme. Selection is internal-only, so there is no change notification —
/// a new theme takes effect on relaunch.
public enum ActiveTheme {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedID = ThemeRegistry.defaultThemeID

    public static var id: ThemeID {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedID
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedID = newValue
        }
    }

    public static var descriptor: ThemeDescriptor { ThemeRegistry.descriptor(id: id) }
}
