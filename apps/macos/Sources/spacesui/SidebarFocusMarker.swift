import Foundation
import spacesterminalcore

/// Decides which sidebar row is marked as the one that receives keystrokes, and where the sidebar's
/// selection has to go so that row is visible.
///
/// The marker names the last terminal session that held keyboard focus, so it is sticky: it moves only
/// when a terminal pane gains focus. Focus leaving for a code pane, a dialog, the palette, or another
/// app is not an event here at all, which is what keeps the row marked through them.
enum SidebarFocusMarker {
    /// Where the sidebar lists the row of a focused terminal session.
    struct RowLocation: Equatable {
        let workspaceID: String
        let projectID: String
        let isProjectCollapsed: Bool
        let kind: AppKitController.WorkspaceRunShortcutTarget.Kind
    }

    /// How the selected workspace's panel is restored when focus moves the selection: the terminal that
    /// just gained focus already has the keyboard, so restored panes must not take it.
    static let selectionFocusIntent = TerminalOpenFocusIntent.withoutFocus

    struct Outcome: Equatable {
        /// The session whose row carries the marker; nil while no terminal has held focus yet.
        let markedSessionID: String?
        /// The workspace the sidebar selection moves to, or nil to leave the selection alone.
        let selectWorkspaceID: String?
        /// A collapsed project to expand before selecting, so the marked row is on screen.
        let expandProjectID: String?
    }

    /// - Parameters:
    ///   - focusedSessionID: The terminal session that just gained focus, or nil when focus is somewhere
    ///     that is not a terminal pane (a code pane, the palette, a dialog) or Spaces is not frontmost.
    ///   - location: Where the sidebar lists `focusedSessionID`'s row, or nil when it has none (a hidden
    ///     workspace, a session the sidebar does not know yet).
    static func outcome(previousMarkedSessionID: String?, focusedSessionID: String?, location: RowLocation?, selectedWorkspaceID: String?) -> Outcome
    {
        guard let focusedSessionID else { return Outcome(markedSessionID: previousMarkedSessionID, selectWorkspaceID: nil, expandProjectID: nil) }
        // A newly focused terminal replaces the previous marker even when it has no row: keeping the old
        // row marked would point at a terminal that no longer gets the keystrokes.
        guard let location, location.kind.isTerminalBacked else {
            return Outcome(markedSessionID: focusedSessionID, selectWorkspaceID: nil, expandProjectID: nil)
        }
        let expandProjectID = location.isProjectCollapsed ? location.projectID : nil
        // Only a workspace selection follows focus. Alerts, Automations, Resources, Prompts, and a project's
        // own page clear the workspace selection, and a terminal focused in a panel window must not pull the
        // main window away from a page the user opened on purpose.
        guard let selectedWorkspaceID, location.workspaceID != selectedWorkspaceID else {
            return Outcome(markedSessionID: focusedSessionID, selectWorkspaceID: nil, expandProjectID: expandProjectID)
        }
        return Outcome(markedSessionID: focusedSessionID, selectWorkspaceID: location.workspaceID, expandProjectID: expandProjectID)
    }

    /// Whether a target row carries the marker. Browser sessions never do, and a row with no session
    /// (a configured process that is not running) has nothing to hold focus.
    static func marksRow(kind: AppKitController.WorkspaceRunShortcutTarget.Kind, sessionID: String?, markedSessionID: String?) -> Bool {
        guard kind.isTerminalBacked, let sessionID, let markedSessionID else { return false }
        return sessionID == markedSessionID
    }
}

extension AppKitController.WorkspaceRunShortcutTarget.Kind {
    var isTerminalBacked: Bool {
        switch self {
        case .browser: return false
        case .process, .window, .missingConfiguredProcess, .agent, .pinnedThread: return true
        }
    }
}
