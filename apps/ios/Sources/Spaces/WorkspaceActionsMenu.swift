import SwiftUI
import spacesdevicecore

/// The workspace band's trailing actions: a menu opened from a small `ellipsis` pill, replacing a
/// dedicated control-bar row so an idle, empty workspace costs one compact band instead of a band plus a
/// row of pills plus an empty-state line.
///
/// Lifecycle actions follow the workspace's state rather than being shown-but-disabled: a stopped
/// workspace offers Start alone; a running one offers Restart and Stop, plus Start alongside them when a
/// configured process is still missing (an ad hoc terminal or agent session can mark the workspace
/// running on its own). This matches the Mac sidebar's workspace context menu.
///
/// Starting a workspace launches its configured processes, not its coding agents, browser sessions, or ad
/// hoc terminals, none of which the daemon opens on Start, so Terminal stays a separate action.
struct WorkspaceActionsMenu: View {
    let workspace: SpacesDeviceWorkspaceSummary
    /// A shared-channel mutation is in flight. The model runs those one at a time and drops a second one
    /// silently, so every item that rides that channel (Start, Restart, Stop, New Terminal, Hide) is
    /// disabled until it settles. Delete runs on its own channel and stays enabled, matching the band's
    /// long-press/swipe Delete.
    let isMutating: Bool
    /// This workspace's own delete is pending, which leaves the whole menu inert. Another workspace's
    /// delete never sets it (#450; see the call site).
    let isDeleting: Bool
    let onStart: () -> Void
    let onRestart: () -> Void
    let onStop: () -> Void
    /// Opens an ad hoc terminal. `nil` hides the Terminal item for backends that cannot open one (Demo
    /// Mode), so the menu never offers a control the backend rejects.
    let onNewTerminal: (() -> Void)?
    /// `nil` hides the Hide item under the same rule `WorkspaceBandActions` applies to the band's own
    /// long-press/swipe surface: Demo Mode's backend cannot serve it, and a workspace already marked for
    /// deletion is inert by contract.
    let onHide: (() -> Void)?
    /// `nil` hides the Delete item: the two rules above, plus the daemon refusing to delete a default
    /// workspace or any workspace of the home project (see `workspaceCanBeDeleted` at the call site).
    let onDelete: (() -> Void)?

    /// Whether the menu offers Start/Restart/Stop at all. The home project has no configured processes to
    /// start and no lifecycle of its own: its one workspace is marked running by an ordinary ad hoc
    /// terminal launch, the same as any other workspace's loose terminal, and stops again when the last
    /// terminal ends. There is nothing a lifecycle action here would act on. Gated on `projectKind`, never
    /// the workspace's name or directory, since the kind is the daemon's own authoritative signal for
    /// which project is the home one.
    var offersLifecycle: Bool { workspace.projectKind.hasWorkspaceLifecycle }

    /// Whether Start should be offered even while `workspace.isRunning` is true, mirroring the Mac
    /// footer/sidebar's `workspaceLifecycleControlsOfferStart`. `isRunning` turns true the moment an ad
    /// hoc terminal or coding-agent session starts and says nothing about whether any configured process
    /// is actually running, so a workspace can be `isRunning` from ad hoc runtime alone with a configured
    /// process still missing. `canRun` is true for a configured-process row the daemon has not reported as
    /// `.running` (exited or never launched), so its presence is exactly "Start has something to do."
    var offersStart: Bool { offersLifecycle && (!workspace.isRunning || workspace.processRows.contains { $0.canRun }) }

    /// The two lifecycle items' show conditions, factored out so `hasActions` and `body` read the same
    /// predicate instead of two copies that could drift. The other three items (New Terminal, Hide,
    /// Delete) are already a single source of truth: each is shown exactly when its closure is non-nil, so
    /// `hasActions` and `body` both just test the closure directly.
    private var showsStart: Bool { offersStart }
    private var showsRestartAndStop: Bool { workspace.isRunning && offersLifecycle }

    /// Whether the menu has anything to show. A workspace can offer no lifecycle, no ad hoc terminal
    /// (Demo Mode), no Hide, and no Delete (the home project) all at once, in which case the caller must
    /// render no pill at all rather than a menu whose only content is its section title.
    var hasActions: Bool { showsStart || showsRestartAndStop || onNewTerminal != nil || onHide != nil || onDelete != nil }

    var body: some View {
        Menu {
            Section(workspace.displayName) {
                if showsStart {
                    Button {
                        onStart()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }.disabled(isMutating).accessibilityIdentifier("workspace.start.\(workspace.id)")
                }
                if showsRestartAndStop {
                    Button {
                        onRestart()
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }.disabled(isMutating).accessibilityIdentifier("workspace.restart.\(workspace.id)")
                    Button(role: .destructive) {
                        onStop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }.disabled(isMutating).accessibilityIdentifier("workspace.stop.\(workspace.id)")
                }
                if let onNewTerminal {
                    Button {
                        onNewTerminal()
                    } label: {
                        Label("New Terminal", systemImage: "terminal")
                    }.disabled(isMutating).accessibilityIdentifier("workspace.newTerminal.\(workspace.id)")
                }
            }
            Section {
                if let onHide {
                    Button {
                        onHide()
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                    }.disabled(isMutating).accessibilityIdentifier("workspace.hide.\(workspace.id)")
                }
                if let onDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }.accessibilityIdentifier("workspace.delete.\(workspace.id)")
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .regular)).foregroundStyle(Theme.muted).frame(width: 30, height: 24)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous)).overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
                ).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(isDeleting).opacity(isDeleting ? 0.5 : 1).accessibilityLabel("Workspace actions").accessibilityIdentifier(
            "workspace.actions.\(workspace.id)")
    }
}
