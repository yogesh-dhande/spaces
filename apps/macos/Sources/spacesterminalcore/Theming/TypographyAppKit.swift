#if canImport(AppKit)
    import AppKit

    /// AppKit adapter over the chrome type scale.
    ///
    /// The role definitions live in ``TypographyRole``, which stays platform-neutral; this type only
    /// resolves them to `NSFont`s so call sites read `label.font = Typography.rowLabel`. It sits in
    /// `spacesterminalcore` rather than next to `Theme` because `spacesterminalui` and
    /// `spacesterminalghostty` draw chrome too and neither can import `spacesui`.
    public enum Typography {
        // MARK: Titles

        /// Heading of a top-level pane or window (workspace detail, Alerts).
        public static var pageTitle: NSFont { font(.pageTitle) }
        /// Heading of a sheet, form window, setup step, or the command palette.
        public static var sheetTitle: NSFont { font(.sheetTitle) }
        /// Heading of a large card that leads a pane.
        public static var cardTitle: NSFont { font(.cardTitle) }
        /// Centered headline of an empty, loading, or placeholder pane.
        public static var emptyStateTitle: NSFont { font(.emptyStateTitle) }
        /// Heading of a section inside a card or dialog, and the sidebar's own header.
        public static var sectionTitle: NSFont { font(.sectionTitle) }
        /// Name of a compact element (banner, pane footer, breadcrumb) and the key of a labeled value.
        public static var compactTitle: NSFont { font(.compactTitle) }

        // MARK: Rows and body

        /// Primary identifying label of a list row.
        public static var rowLabel: NSFont { font(.rowLabel) }
        /// Explanatory copy and body-size text entry.
        public static var body: NSFont { font(.body) }
        /// Title of a primary action button.
        public static var primaryButtonLabel: NSFont { font(.primaryButtonLabel) }
        /// Title of a secondary action button.
        public static var secondaryButtonLabel: NSFont { font(.secondaryButtonLabel) }
        /// Title of a borderless text button.
        public static var textButtonLabel: NSFont { font(.textButtonLabel) }
        /// Label of an interactive control, an inline rename editor, or a dense row's name.
        public static var controlLabel: NSFont { font(.controlLabel) }
        /// Secondary detail beside or below a label, and copy inside a compact dialog.
        public static var rowDetail: NSFont { font(.rowDetail) }

        // MARK: Quiet text

        /// Quiet header above a field or group, and the emphasized half of a dense two-part row.
        public static var metadataTitle: NSFont { font(.metadataTitle) }
        /// Quiet text that should still register: counts, low-emphasis actions, the focused pane's name.
        public static var metadataEmphasis: NSFont { font(.metadataEmphasis) }
        /// Quiet supporting text: hints, subtitles, secondary row detail.
        public static var metadata: NSFont { font(.metadata) }
        /// Smallest text that still carries an identity, such as the workspace tag on a dense row.
        public static var captionTitle: NSFont { font(.captionTitle) }
        /// Smallest supporting text: shortcut hints, footer legends, separators.
        public static var caption: NSFont { font(.caption) }

        // MARK: Monospaced

        /// Monospaced primary label of a row (a terminal pane's title).
        public static var monoRowLabel: NSFont { font(.monoRowLabel) }
        /// Monospaced body: commands, script editors, captured shortcuts, log and output views.
        public static var monoBody: NSFont { font(.monoBody) }
        /// Monospaced quiet text: paths, script previews, environment blocks, branch chips, log tails.
        public static var monoMetadata: NSFont { font(.monoMetadata) }
        /// Smallest monospaced supporting text, such as a branch on a dense row.
        public static var monoCaption: NSFont { font(.monoCaption) }
        /// Monospaced chip or badge text: keyboard shortcuts and result counts.
        public static var monoBadge: NSFont { font(.monoBadge) }
        /// Monospaced badge text that has to carry weight of its own: type tiles and alert counts.
        public static var monoBadgeStrong: NSFont { font(.monoBadgeStrong) }

        // MARK: Variants

        /// Digit-monospaced variant of a role's font, for text where numbers have to line up rather
        /// than reflow: version numbers set side by side, counters that tick. It is a variant, not a
        /// role — size and weight still come from the role the call site picked, and only the digit
        /// advance changes — so the scale stays the single place a size is decided.
        public static func tabularDigits(_ font: NSFont) -> NSFont {
            let descriptor = font.fontDescriptor.addingAttributes([
                .featureSettings: [
                    [
                        NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                        NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                    ]
                ]
            ])
            return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }

        // MARK: Helpers

        private static func font(_ role: TypographyRole) -> NSFont {
            let spec = role.spec
            let size = CGFloat(spec.points)
            let weight: NSFont.Weight =
                switch spec.weight {
                case .regular: .regular
                case .medium: .medium
                case .semibold: .semibold
                }
            return spec.isMonospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        }
    }
#endif
