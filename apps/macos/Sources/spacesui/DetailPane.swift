/// The single content shown in the main window's detail pane. Exactly one of these is
/// current at a time, so presenting one replaces whatever was there.
///
/// Settings is deliberately not modeled here: it opens as a floating dialog that leaves
/// the detail pane in place, so its open state lives in `AppKitController.showingSettings`
/// and coexists with any of these panes.
enum DetailPane: Equatable {
    case none
    /// A workspace's panel (its terminal panes) with the action footer. The owning device is carried on
    /// the pane rather than looked up from the sidebar data, so it stays known after the workspace drops
    /// out of that data: an offline or wire-incompatible daemon answers with an empty overview, and
    /// telling that apart from a deletion is what decides whether the pane survives a reload.
    case workspace(id: String, deviceID: String)
    /// The full-pane alerts list.
    case alerts
    /// The full-pane compatibility block for an incompatible device's daemon. Held here (rather than
    /// only in the sidebar selection) so the block survives background sidebar reloads instead of
    /// being replaced.
    case compatibilityBlock(deviceID: String)

    /// Workspace whose detail is shown, or `nil` for any other pane.
    var workspaceID: String? { if case .workspace(let id, _) = self { id } else { nil } }

    /// Device owning the workspace whose detail is shown, or `nil` for any other pane.
    var workspaceDeviceID: String? { if case .workspace(_, let deviceID) = self { deviceID } else { nil } }

    /// Whether the alerts list is the current pane.
    var isAlerts: Bool { if case .alerts = self { true } else { false } }

    /// Device whose compatibility block is shown, or `nil` for any other pane.
    var compatibilityBlockDeviceID: String? { if case .compatibilityBlock(let deviceID) = self { deviceID } else { nil } }
}

/// Why the detail pane is being presented. The `show*` methods serve both roles — they are the
/// navigation entry points *and* the pane's re-render — and only the caller knows which one it is, so
/// the intent is passed in rather than inferred from what changed.
///
/// It decides one thing: whether the free-standing New Project / New Workspace / project settings
/// windows are dismissed. Content changing is not evidence of navigation, because a background refresh
/// changes it too — a remote device turning wire-incompatible swaps the pane for its compatibility
/// block, recovery swaps it back, a failed reload swaps in the error placeholder, and a selected
/// workspace deleted elsewhere resolves the pane to the neutral placeholder. Dismissing a form the
/// user is filling in on any of those loses their input.
enum DetailPanePresentation {
    /// The user asked for this pane: a sidebar row selection, the Alerts row or its shortcut, arrow
    /// navigation, the compatibility caption's button. Moving the pane out from under a form window is
    /// what dismisses it.
    case userNavigation
    /// A refresh or reconcile re-resolved the pane from new device state. Never dismisses a form
    /// window, whatever it does to the pane's content.
    ///
    /// This is the default because it is the harmless verdict: a background path miscategorized as
    /// navigation destroys work the user cannot get back, while navigation miscategorized as background
    /// only leaves a dialog open a moment longer.
    case backgroundRefresh
}
