import SwiftUI
import spacesterminalcore

/// Shared SwiftUI row/section primitives for the iOS app.
///
/// These mirror the AppKit primitives in
/// `apps/macos/Sources/spacesui/RowPrimitives.swift` and the row/section
/// vocabulary in `docs/design.md`: status dots, type-icon tiles, metadata
/// chips, and the section card. Build on these before inventing one-off styles.

// MARK: - Status dot

/// Compact status indicator: 14pt slot, 8pt dot, 1.5pt stroke for outlined states.
struct StatusDot: View {
    enum Kind {
        case running
        case idle
        case exited
        case waiting

        init(_ state: TerminalSessionState) {
            switch state {
            case .running: self = .running
            case .starting: self = .waiting
            case .exited: self = .idle
            case .failed: self = .exited
            }
        }
    }

    let kind: Kind

    var body: some View {
        ZStack {
            if kind == .running {
                Circle().fill(Theme.statusRunningHalo).frame(width: 14, height: 14)
                Circle().fill(Theme.green).frame(width: 8, height: 8)
            } else if kind == .waiting {
                Circle().fill(Theme.orange).frame(width: 8, height: 8)
            } else {
                Circle()
                    .strokeBorder(strokeColor, lineWidth: 1.5)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 14, height: 14)
    }

    private var strokeColor: Color {
        switch kind {
        case .exited: Theme.red
        default: Theme.mutedSecondary
        }
    }
}

// MARK: - Type-icon tile

/// 22×22 rounded tile with a tinted background and SF Symbol glyph.
struct TypeIconTile: View {
    let systemName: String
    var background: Color = Theme.accentTint
    var foreground: Color = Theme.accentStrong

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(background)
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(foreground)
            )
    }
}

// MARK: - Project glyph

/// The marketing site's project glyph: two nodes on the left merging into one on
/// the right (the `apps/web` `ProjectIcon`, and the AppKit `RowPrimitives.projectGlyphImage`).
/// Paths are laid out in a 20×20 space and scaled to `size`, so the 1.4pt stroke scales
/// with it.
struct ProjectIcon: View {
    var size: CGFloat = 13
    var color: Color = Theme.mutedSecondary

    var body: some View {
        ProjectIconShape()
            .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .frame(width: 20, height: 20)
            .scaleEffect(size / 20)
            .frame(width: size, height: size)
    }
}

private struct ProjectIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius: CGFloat = 1.8
        for center in [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 15), CGPoint(x: 15, y: 10)] {
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        // Top-left node elbows down into the right node; cubic control points
        // approximate the SVG's radius-2 quarter-circle corner.
        path.move(to: CGPoint(x: 6.8, y: 5))
        path.addLine(to: CGPoint(x: 11, y: 5))
        path.addCurve(to: CGPoint(x: 13, y: 7), control1: CGPoint(x: 12.105, y: 5), control2: CGPoint(x: 13, y: 5.895))
        path.addLine(to: CGPoint(x: 13, y: 8))
        // Bottom-left node elbows up into the right node.
        path.move(to: CGPoint(x: 6.8, y: 15))
        path.addLine(to: CGPoint(x: 11, y: 15))
        path.addCurve(to: CGPoint(x: 13, y: 13), control1: CGPoint(x: 12.105, y: 15), control2: CGPoint(x: 13, y: 14.105))
        path.addLine(to: CGPoint(x: 13, y: 12))
        return path
    }
}

// MARK: - Metadata chip

/// Small low-contrast chip for short metadata (state, ports, shortcuts).
struct MetaChip: View {
    let text: String
    var monospaced = false

    var body: some View {
        Text(text)
            .font(monospaced ? .system(size: 11, weight: .regular, design: .monospaced) : .system(size: 11))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Theme.chipBg, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Section card

/// Token-backed section container: `Theme.surface` fill, 10pt radius, soft border.
/// Callers compose a header, `RowDivider`s, and rows inside; the card only owns
/// the surface, radius, and clipping.
struct SectionCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Compact section header row: semibold title, optional muted count, trailing slot.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, count: Int? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.count = count
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.init(top: 10, leading: 14, bottom: 10, trailing: 14))
    }
}

// MARK: - Buttons

/// Primary action button: bright-teal fill with dark ink, matching the macOS
/// `Theme.applyPrimaryStyle` treatment.
struct BrandPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.primaryButtonText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.primaryButtonFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Labeled inset text field used in compact brand forms.
struct BrandTextField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)
            TextField(placeholder, text: $text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Thin inset divider between rows inside a section card.
struct RowDivider: View {
    var inset: CGFloat = 14

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}
