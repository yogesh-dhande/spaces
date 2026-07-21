import SwiftUI
import spacesdevicecore

/// Workspace-level controls, shown at the top of an expanded workspace's rows.
///
/// Lifecycle actions follow the workspace's state rather than being shown-but-disabled: a stopped
/// workspace can only be started, so it offers Start alone; a running one offers Restart and Stop.
/// This matches the Mac sidebar's workspace context menu.
///
/// Starting a workspace launches its configured processes and coding agents — not its browser sessions
/// or ad hoc terminals, which the daemon never opens — so Terminal stays a separate action.
struct WorkspaceControlBar: View {
    let workspace: SpacesDeviceWorkspaceSummary
    let isMutating: Bool
    let onStart: () -> Void
    let onRestart: () -> Void
    let onStop: () -> Void
    /// Opens an ad hoc terminal. `nil` hides the Terminal action for backends that cannot open one
    /// (Demo Mode), so the bar never offers a control the backend rejects.
    let onNewTerminal: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if workspace.isRunning {
                WorkspaceControlButton(
                    title: "Restart", systemImage: "arrow.clockwise", tint: Theme.muted, identifier: "workspace.restart.\(workspace.id)",
                    action: onRestart)
                WorkspaceControlButton(
                    title: "Stop", systemImage: "stop.fill", tint: Theme.red, identifier: "workspace.stop.\(workspace.id)", action: onStop)
            } else {
                WorkspaceControlButton(
                    title: "Start", systemImage: "play.fill", tint: Theme.accent, identifier: "workspace.start.\(workspace.id)", action: onStart)
            }
            if let onNewTerminal {
                WorkspaceControlButton(
                    title: "Terminal", systemImage: "plus", tint: Theme.muted, identifier: "workspace.newTerminal.\(workspace.id)", action: onNewTerminal)
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
