import Foundation
import spacesdevicecore

/// One paired device's overview plus what the Agents and Alerts tabs need to know about it, to derive
/// rows across every paired device at once instead of only the selected one.
struct SpacesMobileDeviceOverviewContext: Sendable {
    let deviceID: String
    let deviceName: String
    let overview: SpacesDeviceOverviewPayload
    /// Whether this device's overview stream has failed to connect or dropped since its last delivered
    /// overview (see `SpacesMobileAppModel.offlineDeviceIDs`). An offline device's rows stay listed,
    /// dimmed; a device going offline also widens `showsDeviceSegment` for every row, not only its own, so
    /// the stale rows can explain themselves without the user having to check which device the list means.
    let isOffline: Bool
}

/// The "· device" segment Agents/Alerts rows append to their project/workspace text, and the rule for
/// when it appears at all.
enum SpacesMobileDeviceDisplay {
    /// Mirrors the Mac sidebar's rule (`AppKitController.sidebarShowsDeviceHeaders`): hidden only when
    /// there is exactly one paired device and it is online, since naming it then is noise. A second
    /// paired device, or any offline device, makes every row across every device show its segment
    /// together, so an offline solo device's stale rows explain themselves too.
    static func showsDeviceSegment(pairedDeviceCount: Int, hasOfflineDevice: Bool) -> Bool { pairedDeviceCount > 1 || hasOfflineDevice }

    /// "Device Name" when reachable, "Device Name (offline)" when not.
    static func text(name: String, isOffline: Bool) -> String { isOffline ? "\(name) (offline)" : name }

    /// The "project / workspace" identity text an Agents/Alerts row shows. Matches the Mac Alerts
    /// table's project/workspace segments (`AlertsController.alertsCombinedSegments`), and always names
    /// both even when the workspace repeats the project's name, since a bare workspace name is ambiguous
    /// once a project can have more than one workspace.
    static func projectWorkspace(projectName: String, workspaceDisplayName: String) -> String { "\(projectName) / \(workspaceDisplayName)" }
}
