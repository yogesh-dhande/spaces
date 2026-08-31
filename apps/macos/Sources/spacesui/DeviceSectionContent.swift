import Foundation
import spacesdevicecore
import workspacecore

/// Everything a device section displays, derived purely from one overview payload.
/// One derivation feeds every apply path so the sidebar rows, runtime status, and
/// alerts (with their visibility flags) can never come from different overviews.
struct DeviceSectionContent {
    var projects: [ProjectSummary]
    var workspacesByProject: [String: [WorkspaceSummary]]
    var workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus]
    var alertsGroups: [AppKitController.AlertsGroup]

    nonisolated static func derive(
        from overview: SpacesDeviceOverviewPayload, deviceID: String, deviceName: String, projectCollapseStates: [String: Bool]
    ) -> DeviceSectionContent {
        let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID, projectCollapseStates: projectCollapseStates)
        return DeviceSectionContent(
            projects: mapped.projects, workspacesByProject: mapped.workspacesByProject,
            workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID,
            alertsGroups: AppKitController.buildOverviewAlertsGroups(from: overview, deviceID: deviceID, deviceName: deviceName))
    }
}
