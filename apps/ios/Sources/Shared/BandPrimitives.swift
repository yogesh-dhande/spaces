import SwiftUI
import spacesdevicecore

/// The iOS list separation device: a full-bleed `Theme.surface2` band holds a group header and
/// the rows sit plain on `Theme.bg` beneath it — no cards, borders, or per-row dividers.

// MARK: - Header band

struct HeaderBand<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(Theme.surface2)
    }
}

/// Leading glyph + workspace name band content shared by the Spaces and Alerts tabs.
struct WorkspaceBandLabel: View {
    let isGitWorkspace: Bool
    let displayName: String

    var body: some View {
        Image(systemName: isGitWorkspace ? "arrow.triangle.branch" : "folder")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.mutedSecondary)
        Text(displayName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
    }
}

// MARK: - Band row

/// Shared row anatomy: leading status dot, type-icon tile, title + detail, trailing slot.
///
/// `dotKind` is optional because not every row family has a run state — a browser session is a URL,
/// not a process. Those rows hold the dot's slot empty rather than draw a dot, so the icon column
/// stays aligned with the rows above and below.
struct BandRow<Trailing: View>: View {
    let dotKind: StatusDot.Kind?
    let tile: TypeIconTile
    let title: String
    let detail: String
    var detailIsMonospaced = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            if let dotKind {
                StatusDot(kind: dotKind)
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
            tile
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(detail)
                    .font(detailIsMonospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
                    .foregroundStyle(Theme.mutedSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Muted disclosure chevron for rows that open a detail view.
struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.mutedSecondary)
    }
}

/// Accent play glyph for rows whose primary action launches the row.
struct RowPlayIndicator: View {
    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.accent)
    }
}

// MARK: - Status mapping

extension SpacesMobileWorkspaceRuntimeRow {
    /// The row's leading dot carries its state: coding agents reflect activity (waiting/done/
    /// spinning), everything else reflects run state. Browser sessions have no run state of their
    /// own, so they get no dot.
    var statusDotKind: StatusDot.Kind? {
        switch source {
        case .codingAgent(let agent):
            StatusDot.Kind(runState: agent.runState, activityState: agent.activityState)
        case .browserSession:
            nil
        case .process, .terminal:
            StatusDot.Kind(runState: runState)
        }
    }
}

extension StatusDot.Kind {
    init(runState: SpacesDeviceRunState) {
        switch runState {
        case .running: self = .running
        case .exited: self = .exited
        case .notStarted: self = .idle
        }
    }

    init(runState: SpacesDeviceRunState, activityState: SpacesDeviceCodingAgentActivityState) {
        switch activityState {
        case .waiting: self = .waiting
        case .done: self = .done
        case .spinning: self = .running
        case .idle: self = StatusDot.Kind(runState: runState)
        }
    }

    init(attentionKind: SpacesMobileAttentionEvent.Kind) {
        switch attentionKind {
        case .waitingForInput: self = .waiting
        case .finished: self = .done
        case .exited, .failed: self = .exited
        }
    }
}
