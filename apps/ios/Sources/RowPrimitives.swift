import SwiftUI
import spacesterminalcore

/// Shared SwiftUI row primitives for the iOS app.
///
/// These mirror the AppKit primitives in
/// `apps/macos/Sources/spacesui/RowPrimitives.swift` and the row vocabulary in
/// `docs/design.md`: status dots and type-icon tiles. Build on these before
/// inventing one-off styles.

// MARK: - Status dot

/// Compact status indicator: 14pt slot, 8pt dot, 1.5pt stroke for outlined states.
struct StatusDot: View {
    enum Kind {
        case running
        /// Solid green with no halo or pulse — a finished coding agent, distinct from the running dot.
        case done
        case idle
        case exited
        case waiting

        init(_ state: TerminalSessionState) {
            switch state {
            case .starting, .running: self = .running
            case .exited, .failed: self = .exited
            }
        }
    }

    let kind: Kind

    var body: some View {
        ZStack {
            if kind == .running {
                Circle().fill(Theme.statusRunningHalo).frame(width: 14, height: 14)
                Circle().fill(Theme.green).frame(width: 8, height: 8)
            } else if kind == .done {
                Circle().fill(Theme.green).frame(width: 8, height: 8)
            } else if kind == .waiting {
                Circle().fill(Theme.orange).frame(width: 8, height: 8)
            } else {
                Circle().strokeBorder(strokeColor, lineWidth: 1.5).frame(width: 8, height: 8)
            }
        }.frame(width: 14, height: 14)
    }

    private var strokeColor: Color {
        switch kind {
        case .exited: Theme.statusFailed
        default: Theme.mutedSecondary
        }
    }
}

// MARK: - Type-icon tile

/// 24×24 rounded tile with a tinted background and SF Symbol glyph.
struct TypeIconTile: View {
    let systemName: String
    var background: Color = Theme.accentTint
    var foreground: Color = Theme.accentStrong

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(background).frame(width: 24, height: 24).overlay(
            Image(systemName: systemName).font(.system(size: 12, weight: .regular)).foregroundStyle(foreground))
    }
}

extension TypeIconTile {
    /// The tile treatment for each runtime row family: green for processes, neutral for
    /// coding agents, accent for terminals and browser sessions. Terminals and browser sessions
    /// share the accent tile the Mac gives its browser rows; their glyphs tell them apart.
    static func tile(for type: SpacesMobileWorkspaceRowType) -> TypeIconTile {
        switch type {
        case .processes: TypeIconTile(systemName: type.iconName, background: Theme.green.opacity(0.16), foreground: Theme.green)
        case .codingAgents: TypeIconTile(systemName: type.iconName, background: Theme.chipBg, foreground: Theme.muted)
        case .workspaceTerminals, .browserSessions: TypeIconTile(systemName: type.iconName)
        }
    }
}

// MARK: - Buttons

/// Primary action button: bright-teal fill with dark ink, matching the macOS
/// `Theme.applyPrimaryStyle` treatment.
struct BrandPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primaryButtonText).frame(maxWidth: .infinity).padding(
            .vertical, 12
        ).background(Theme.primaryButtonFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Labeled inset text field used in compact brand forms.
struct BrandTextField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            TextField(placeholder, text: $text).font(.system(size: 14)).foregroundStyle(Theme.text).textInputAutocapitalization(.never)
                .autocorrectionDisabled().padding(.horizontal, 10).padding(.vertical, 8).background(
                    Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
