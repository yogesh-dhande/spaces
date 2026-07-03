#if canImport(AppKit)
    import AppKit
    import spacesterminalcore

    extension NSColor {
        /// AppKit conversion for a shared theme color.
        public convenience init(themeColor: ThemeColor) {
            self.init(
                srgbRed: CGFloat(themeColor.red) / 255.0, green: CGFloat(themeColor.green) / 255.0, blue: CGFloat(themeColor.blue) / 255.0,
                alpha: CGFloat(themeColor.alpha))
        }

        /// Appearance-dynamic color for one active-theme token, for terminal-native chrome
        /// that lives below `spacesui` (panes, mirror views) but must match the app theme.
        public static func activeTheme(_ token: KeyPath<ThemeAppearanceTokens, ThemeColor>) -> NSColor {
            NSColor(name: nil) { appearance in
                let descriptor = ActiveTheme.descriptor
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(themeColor: (isDark ? descriptor.dark : descriptor.light)[keyPath: token])
            }
        }
    }
#endif
