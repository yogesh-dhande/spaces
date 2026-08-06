import Foundation

/// The weights the chrome type scale uses. Roles own their weight, so a call site never
/// picks size and weight independently.
public enum TypographyWeight: Sendable, Equatable {
    case regular
    case medium
    case semibold
}

/// The resolved shape of one typography role.
public struct TypographySpec: Sendable, Equatable {
    /// Point size. Always one of `TypographyRole.scale`.
    public let points: Double
    public let weight: TypographyWeight
    /// Monospaced roles are reserved for paths, commands, branches, shortcuts, ports, and scripts.
    public let isMonospaced: Bool

    public init(points: Double, weight: TypographyWeight, isMonospaced: Bool = false) {
        self.points = points
        self.weight = weight
        self.isMonospaced = isMonospaced
    }
}

/// App-chrome text roles. A call site picks a role by what the text *is*, never by what size it
/// should be, and the role fixes both the size and the weight.
///
/// This lives outside `ThemeDescriptor` on purpose: text sizing is a property of the chrome, not of
/// the palette, so switching themes must never move text. `TypographyAppKit` renders these as
/// `NSFont`s; this file stays platform-neutral because `spacesterminalcore` cross-compiles for Linux.
///
/// Terminal *content* is not chrome and is sized separately, by the user: `TerminalTextSize` on macOS
/// and `TerminalFontSize` on iOS. These roles cover only the interface drawn around it.
public enum TypographyRole: CaseIterable, Sendable {
    /// Heading of a top-level pane or window (workspace detail, Alerts).
    case pageTitle
    /// Heading of a sheet, form window, setup step, or the command palette.
    case sheetTitle
    /// Heading of a large card that leads a pane.
    case cardTitle
    /// Centered headline of an empty, loading, or placeholder pane.
    case emptyStateTitle
    /// Heading of a section inside a card or dialog, and the sidebar's own header.
    case sectionTitle
    /// Primary identifying label of a list row.
    case rowLabel
    /// Explanatory copy and body-size text entry.
    case body
    /// Title of a primary action button.
    case primaryButtonLabel
    /// Title of a secondary action button.
    case secondaryButtonLabel
    /// Title of a borderless text button.
    case textButtonLabel
    /// Name of a compact element (banner, pane footer, breadcrumb) and the key of a labeled value.
    case compactTitle
    /// Label of an interactive control, an inline rename editor, or a dense row's name.
    case controlLabel
    /// Secondary detail beside or below a label, and copy inside a compact dialog.
    case rowDetail
    /// Quiet header above a field or group, and the emphasized half of a dense two-part row.
    case metadataTitle
    /// Quiet text that should still register: counts, low-emphasis actions, the focused pane's name.
    case metadataEmphasis
    /// Quiet supporting text: hints, subtitles, secondary row detail.
    case metadata
    /// Smallest text that still carries an identity, such as the workspace tag on a dense row.
    case captionTitle
    /// Smallest supporting text: shortcut hints, footer legends, separators.
    case caption

    /// Monospaced primary label of a row (a terminal pane's title).
    case monoRowLabel
    /// Monospaced body: commands, script editors, captured shortcuts, log and output views.
    case monoBody
    /// Monospaced quiet text: paths, script previews, environment blocks, branch chips, log tails.
    case monoMetadata
    /// Smallest monospaced supporting text, such as a branch on a dense row.
    case monoCaption
    /// Monospaced chip or badge text: keyboard shortcuts and result counts.
    case monoBadge
    /// Monospaced badge text that has to carry weight of its own: type tiles and alert counts.
    case monoBadgeStrong

    /// The point sizes the chrome is allowed to use. Off-scale one-offs are what the scale exists to
    /// prevent, so every role's size must appear here.
    public static let scale: [Double] = [20, 16, 14, 13, 12, 11, 10]

    public var spec: TypographySpec {
        switch self {
        case .pageTitle: TypographySpec(points: 20, weight: .semibold)
        case .sheetTitle: TypographySpec(points: 16, weight: .semibold)
        case .cardTitle: TypographySpec(points: 14, weight: .semibold)
        case .emptyStateTitle: TypographySpec(points: 14, weight: .medium)
        case .sectionTitle: TypographySpec(points: 13, weight: .semibold)
        case .rowLabel: TypographySpec(points: 13, weight: .medium)
        case .body: TypographySpec(points: 13, weight: .regular)
        case .primaryButtonLabel: TypographySpec(points: 13, weight: .semibold)
        case .secondaryButtonLabel: TypographySpec(points: 13, weight: .regular)
        case .textButtonLabel: TypographySpec(points: 13, weight: .medium)
        case .compactTitle: TypographySpec(points: 12, weight: .semibold)
        case .controlLabel: TypographySpec(points: 12, weight: .medium)
        case .rowDetail: TypographySpec(points: 12, weight: .regular)
        case .metadataTitle: TypographySpec(points: 11, weight: .semibold)
        case .metadataEmphasis: TypographySpec(points: 11, weight: .medium)
        case .metadata: TypographySpec(points: 11, weight: .regular)
        case .captionTitle: TypographySpec(points: 10, weight: .semibold)
        case .caption: TypographySpec(points: 10, weight: .regular)
        case .monoRowLabel: TypographySpec(points: 12, weight: .medium, isMonospaced: true)
        case .monoBody: TypographySpec(points: 12, weight: .regular, isMonospaced: true)
        case .monoMetadata: TypographySpec(points: 11, weight: .regular, isMonospaced: true)
        case .monoCaption: TypographySpec(points: 10, weight: .regular, isMonospaced: true)
        case .monoBadge: TypographySpec(points: 10, weight: .medium, isMonospaced: true)
        case .monoBadgeStrong: TypographySpec(points: 10, weight: .semibold, isMonospaced: true)
        }
    }
}
