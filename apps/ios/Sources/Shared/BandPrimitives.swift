import SwiftUI
import spacesdevicecore

/// The iOS list separation device: a full-bleed `Theme.surface2` band holds a group header and
/// the rows sit plain on `Theme.bg` beneath it — no cards, borders, or per-row dividers.

// MARK: - Header band

struct HeaderBand<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 8) { content() }.padding(.vertical, 8).padding(.horizontal, 20).frame(maxWidth: .infinity).background(Theme.surface2)
    }
}

/// Leading glyph + workspace name band content shared by the Spaces and Alerts tabs.
struct WorkspaceBandLabel: View {
    let isGitWorkspace: Bool
    let displayName: String

    var body: some View {
        Image(systemName: isGitWorkspace ? "arrow.triangle.branch" : "folder").font(.system(size: 12, weight: .medium)).foregroundStyle(
            Theme.mutedSecondary)
        Text(displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
    }
}

// MARK: - List rows

/// The band design lives inside a `List` so rows can carry swipe actions, but it owns its own spacing
/// and background: every row is full-bleed on `Theme.bg` with no list insets, separators, or row fill.
extension View {
    func bandListRow() -> some View { listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear) }

    /// A header band as a list row, carrying the gap that separates it from the group above and the
    /// smaller gap to the first row beneath it. Both are drawn on the app background, so the band's own
    /// `surface2` fill stays full-bleed.
    func bandListHeaderRow(topGap: CGFloat = 14) -> some View { padding(.top, topGap).padding(.bottom, 4).bandListRow() }
}

// MARK: - Band row

/// Shared row anatomy: leading status dot, type-icon tile, title + detail, trailing slot.
///
/// `dotKind` is optional because not every row family has a run state — a browser session is a URL,
/// not a process. Those rows hold the dot's slot empty rather than draw a dot, so the icon column
/// stays aligned with the rows above and below.
///
/// The title is a view slot, not a string, so a row being renamed can swap a text field into the
/// title's place and keep the rest of the row identical while it is edited.
struct BandRow<Title: View, Trailing: View>: View {
    let dotKind: StatusDot.Kind?
    let tile: TypeIconTile
    @ViewBuilder var title: () -> Title
    let detail: String
    var detailIsMonospaced = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            if let dotKind { StatusDot(kind: dotKind) } else { Color.clear.frame(width: 14, height: 14) }
            tile
            VStack(alignment: .leading, spacing: 1) {
                title().font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                // An empty detail takes no line at all, so a shell sitting at its workspace root reads as
                // a single-line row instead of leaving a blank second line under its name.
                if !detail.isEmpty {
                    Text(detail).font(detailIsMonospaced ? .system(size: 11, design: .monospaced) : .system(size: 12)).foregroundStyle(
                        Theme.mutedSecondary
                    ).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }.padding(.vertical, 9).padding(.horizontal, 20).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

extension BandRow where Title == Text {
    init(
        dotKind: StatusDot.Kind?, tile: TypeIconTile, title: String, detail: String, detailIsMonospaced: Bool = true,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) { self.init(dotKind: dotKind, tile: tile, title: { Text(title) }, detail: detail, detailIsMonospaced: detailIsMonospaced, trailing: trailing) }
}

/// Muted disclosure chevron for rows that open a detail view.
struct RowChevron: View {
    var body: some View { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mutedSecondary) }
}

/// Accent play glyph for rows whose primary action launches the row.
struct RowPlayIndicator: View {
    var body: some View { Image(systemName: "play.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent) }
}

// MARK: - Status mapping

extension SpacesMobileWorkspaceRuntimeRow {
    /// The row's leading dot carries its state: coding agents reflect activity (waiting/done/
    /// spinning), everything else reflects run state. Browser sessions have no run state of their
    /// own, so they get no dot.
    ///
    /// `exitAcknowledged` — see `SpacesMobileAppModel.isExitAcknowledged(_:)` — is read only by a
    /// `.process` row: dismissing the alert for a dead process turns its dot from failed red to the
    /// unstarted stroke, but an agent's or a terminal's dot keeps tracking live state regardless of any
    /// dismissal, so they ignore the parameter.
    func statusDotKind(exitAcknowledged: Bool) -> StatusDot.Kind? {
        switch source {
        case .codingAgent(let agent): return StatusDot.Kind(runState: agent.runState, activityState: agent.activityState)
        case .browserSession: return nil
        case .terminal: return StatusDot.Kind(runState: runState)
        case .process:
            let kind = StatusDot.Kind(runState: runState)
            return kind == .exited && exitAcknowledged ? .idle : kind
        }
    }
}

// MARK: - Alert dismissal

/// The long-press "Dismiss Alert" menu item shared by every row family that can carry undismissed
/// attention events. Dismisses all of the row's undismissed events at once through
/// `SpacesMobileAppModel.dismissAlerts(for:)` — the same persisted `dismissedAlertIDs` path individual
/// dismissal from the Alerts tab uses — so the badge and every other surface showing the same source
/// follow.
struct DismissAlertMenuButton: View {
    let model: SpacesMobileAppModel
    let row: SpacesMobileWorkspaceRuntimeRow

    var body: some View {
        Button {
            model.dismissAlerts(for: row)
        } label: {
            Label("Dismiss Alert", systemImage: "bell.slash")
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
        // Idle means no agent activity, so the dot reflects the terminal's run state (a live shell reads
        // as running). Exited means the agent process is gone even though its terminal stays interactive,
        // so it must read as exited rather than inheriting the terminal's still-running state.
        case .idle: self = StatusDot.Kind(runState: runState)
        case .exited: self = .exited
        }
    }

    init(attentionKind: SpacesMobileAttentionEvent.Kind) {
        switch attentionKind {
        // A bell reads the same as "waiting for input": both mean the session wants the user's attention.
        case .waitingForInput, .bell: self = .waiting
        case .finished: self = .done
        case .exited, .failed: self = .exited
        }
    }
}
