/// The single content shown in the main window's detail pane. Exactly one of these is
/// current at a time, so presenting one replaces whatever was there.
///
/// Settings is deliberately not modeled here: it opens as a floating dialog that leaves
/// the detail pane in place, so its open state lives in `AppKitController.showingSettings`
/// and coexists with any of these panes.
enum DetailPane: Equatable {
    case none
    /// A workspace's panel (its terminal panes) with the action footer.
    case workspace(id: String)
    /// The full-pane alerts list.
    case alerts
    /// The full-pane compatibility block for an incompatible device's daemon. Held here (rather than
    /// only in the sidebar selection) so the block survives background sidebar reloads instead of
    /// being replaced.
    case compatibilityBlock(deviceID: String)

    /// Workspace whose detail is shown, or `nil` for any other pane.
    var workspaceID: String? { if case .workspace(let id) = self { id } else { nil } }

    /// Whether the alerts list is the current pane.
    var isAlerts: Bool { if case .alerts = self { true } else { false } }

    /// Device whose compatibility block is shown, or `nil` for any other pane.
    var compatibilityBlockDeviceID: String? { if case .compatibilityBlock(let deviceID) = self { deviceID } else { nil } }
}
