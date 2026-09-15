import Foundation
import spacesclientcore

/// One candidate of a cycle rotation: the focusable target itself plus the device and workspace it
/// belongs to and the workspace detail it resolves against, so a rotation spanning workspaces can
/// focus each candidate against its own workspace without re-deriving anything mid-cycle.
struct WindowCycleTarget: Sendable {
    let deviceID: String
    let workspaceID: String
    /// Identity for the cursor, the recent-target list, and the frozen rotation. A workspace-scoped
    /// rotation uses the plain per-workspace key; a rotation spanning devices and workspaces uses
    /// `globalCursorKey`, which prefixes that key with both ids so two workspaces' targets never
    /// collide in one list.
    let cursorKey: String
    let target: AppKitController.WorkspaceRunShortcutTarget
    let detail: SpacesDeviceWorkspaceDetailViewModel
    /// The Chrome windows tracked for this target's workspace, empty for every target that is not a
    /// browser session. Matching the frontmost Chrome window id against these is what tells two
    /// workspaces apart when both configured the same target URL and both have it open.
    let trackedBrowserWindowIDs: Set<Int>

    /// The cross-workspace form of a per-workspace cursor key.
    static func globalCursorKey(deviceID: String, workspaceID: String, cursorKey: String) -> String {
        "device:\(deviceID)/workspace:\(workspaceID)/\(cursorKey)"
    }
}
