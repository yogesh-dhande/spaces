import SwiftUI
import spacesdevicecore

/// Workspace-level controls, shown at the top of an expanded workspace's rows.
///
/// Lifecycle actions follow the workspace's state rather than being shown-but-disabled: a stopped
/// workspace offers Start alone; a running one offers Restart and Stop, plus Start alongside them when a
/// configured process is still missing (an ad hoc terminal or agent session can mark the workspace
/// running on its own). This matches the Mac sidebar's workspace context menu.
///
/// Starting a workspace launches its configured processes, not its coding agents, browser sessions, or ad
/// hoc terminals, none of which the daemon opens on Start, so Terminal stays a separate action.
struct WorkspaceControlBar: View {
    let workspace: SpacesDeviceWorkspaceSummary
    let isMutating: Bool
    let onStart: () -> Void
    let onRestart: () -> Void
    let onStop: () -> Void
    /// Opens an ad hoc terminal. `nil` hides the Terminal action for backends that cannot open one
    /// (Demo Mode), so the bar never offers a control the backend rejects.
    let onNewTerminal: (() -> Void)?

    /// Whether Start should be offered even while `workspace.isRunning` is true, mirroring the Mac
    /// footer/sidebar's `workspaceLifecycleControlsOfferStart`. `isRunning` turns true the moment an ad
    /// hoc terminal or coding-agent session starts and says nothing about whether any configured process
    /// is actually running, so a workspace can be `isRunning` from ad hoc runtime alone with a configured
    /// process still missing. `canRun` is true for a configured-process row the daemon has not reported as
    /// `.running` (exited or never launched), so its presence is exactly "Start has something to do."
    private var offersStart: Bool { !workspace.isRunning || workspace.processRows.contains { $0.canRun } }

    var body: some View {
        HStack(spacing: 8) {
            if offersStart {
                WorkspaceControlButton(
                    title: "Start", systemImage: "play.fill", tint: Theme.accent, identifier: "workspace.start.\(workspace.id)", action: onStart)
            }
            if workspace.isRunning {
                WorkspaceControlButton(
                    title: "Restart", systemImage: "arrow.clockwise", tint: Theme.muted, identifier: "workspace.restart.\(workspace.id)",
                    action: onRestart)
                WorkspaceControlButton(
                    title: "Stop", systemImage: "stop.fill", tint: Theme.red, identifier: "workspace.stop.\(workspace.id)", action: onStop)
            }
            if let onNewTerminal {
                WorkspaceControlButton(
                    title: "Terminal", systemImage: "plus", tint: Theme.muted, identifier: "workspace.newTerminal.\(workspace.id)",
                    action: onNewTerminal)
            }
            Spacer(minLength: 0)
        }.disabled(isMutating).opacity(isMutating ? 0.5 : 1).padding(.horizontal, 20).padding(.top, 8)
    }
}

/// Compact pill button used by the workspace control bar. Workspace lifecycle actions are not obvious
/// from an icon alone (Start starts *what*, exactly), so each carries a text label beside its glyph.
private struct WorkspaceControlButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }.foregroundStyle(tint).padding(.horizontal, 9).padding(.vertical, 5).background(
                Theme.surface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            ).overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
}
