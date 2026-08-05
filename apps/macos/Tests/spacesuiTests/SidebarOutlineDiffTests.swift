import Testing
import workspacecore

@testable import spacesui

/// Which sidebar rows an applied device overview repaints. A remote device with live terminal sessions
/// pushes a changed overview several times a second, and rebuilding every row view for each of those is
/// what this diff exists to avoid — so these cover both halves of the contract: a change repaints exactly
/// the rows that render it, and a change of shape still rebuilds the outline.
struct SidebarOutlineDiffTests {
    private static let deviceID = "device-1"

    private func loadedDevice(_ displayName: String = "Studio") -> SidebarRowDeviceTreatment {
        SidebarRowDeviceTreatment(loadState: .loaded, displayName: displayName)
    }

    private func project(_ id: String, isGitRepo: Bool = true, isCollapsed: Bool = false) -> ProjectSummary {
        ProjectSummary(
            id: id, name: id, dir: "/tmp/\(id)", isGitRepo: isGitRepo, defaultBranch: "main", isCollapsed: isCollapsed, deviceID: Self.deviceID)
    }

    private func workspace(_ id: String) -> WorkspaceSummary {
        WorkspaceSummary(id: id, branch: id, dir: "/tmp/\(id)", isRunning: true, isDefault: false, deviceID: Self.deviceID)
    }

    private func runtimeStatus(_ id: String, isRunning: Bool) -> WorkspaceRuntimeStatus {
        WorkspaceRuntimeStatus(
            workspaceID: id, lifecycleState: WorkspaceLifecycleState(isRunning: isRunning), runtimeHealth: .healthy,
            hasTrackedRuntimeIndicators: false, runningProcessCount: 0, exitedProcessCount: 0, waitingAgentWindowCount: 0,
            missingConfiguredProcessCount: 0, missingConfiguredBrowserSessionCount: 0)
    }

    private func targetItem(key: String, title: String) -> SidebarRuntimeTargetItem {
        SidebarRuntimeTargetItem(
            key: key, title: title, detail: nil, kind: .window, runState: .running, shortcutIndex: 1, sessionID: "session-\(key)", canRun: false,
            canStop: true, canRestart: false, processID: nil, processKey: nil, processTemplateID: nil, agentID: nil, launcherName: nil,
            launcherID: nil, isConfigured: false, browserTargetURL: nil)
    }

    private func deviceRow(_ device: SidebarRowDeviceTreatment) -> SidebarOutlineRow {
        SidebarOutlineRow(
            cacheKey: "d:\(Self.deviceID)",
            signature: .device(
                SidebarDeviceRowSignature(
                    displayName: device.displayName ?? "", loadState: device.loadState ?? .loaded, compatibilityActionTitle: nil, isLocal: false,
                    offersRetry: device.loadState?.isOffline == true, isUpdatePending: false)))
    }

    private func projectRow(_ project: ProjectSummary, device: SidebarRowDeviceTreatment) -> SidebarOutlineRow {
        SidebarOutlineRow(
            cacheKey: "p:\(project.id)",
            signature: .project(
                SidebarProjectRowSignature(
                    device: device, project: project, standInWorkspace: nil, standInRuntimeStatus: nil, standInIsPendingDeletion: false,
                    isExpandable: true)))
    }

    private func workspaceRow(
        _ workspace: WorkspaceSummary, device: SidebarRowDeviceTreatment, status: WorkspaceRuntimeStatus? = nil, isPendingDeletion: Bool = false
    ) -> SidebarOutlineRow {
        SidebarOutlineRow(
            cacheKey: "w:\(workspace.id)",
            signature: .workspace(
                SidebarWorkspaceRowSignature(
                    device: device, workspace: workspace, runtimeStatus: status ?? runtimeStatus(workspace.id, isRunning: true),
                    isPendingDeletion: isPendingDeletion, isExpanded: true, hasRuntimeTargets: true)))
    }

    private func targetRow(_ item: SidebarRuntimeTargetItem, workspaceID: String, device: SidebarRowDeviceTreatment) -> SidebarOutlineRow {
        SidebarOutlineRow(
            cacheKey: "rt:\(workspaceID):\(item.key)",
            signature: .runtimeTarget(SidebarRuntimeTargetRowSignature(device: device, item: item, nestedUnderWorkspace: true, isRenaming: false)))
    }

    /// A device header, one git project, one workspace, and that workspace's single target row.
    private func populatedSnapshot(device: SidebarRowDeviceTreatment) -> [SidebarOutlineRow] {
        [
            deviceRow(device), projectRow(project("proj-1"), device: device), workspaceRow(workspace("ws-1"), device: device),
            targetRow(targetItem(key: "terminal:s1", title: "shell"), workspaceID: "ws-1", device: device),
        ]
    }

    @Test func unchangedSnapshotRepaintsNothing() {
        let rows = populatedSnapshot(device: loadedDevice())
        #expect(SidebarOutlineDiff.compute(previous: rows, current: rows) == .unchanged)
    }

    @Test func firstApplyRebuildsTheOutline() {
        // Nothing is painted before the first apply, so there is no baseline to repaint against.
        #expect(SidebarOutlineDiff.compute(previous: nil, current: populatedSnapshot(device: loadedDevice())) == .structureChanged)
    }

    @Test func workspaceStoppingRepaintsOnlyThatWorkspaceRow() {
        let device = loadedDevice()
        var current = populatedSnapshot(device: device)
        current[2] = workspaceRow(workspace("ws-1"), device: device, status: runtimeStatus("ws-1", isRunning: false))
        #expect(SidebarOutlineDiff.compute(previous: populatedSnapshot(device: device), current: current) == .rowsChanged(["w:ws-1"]))
    }

    @Test func workspaceDeleteMarkingRepaintsOnlyThatWorkspaceRow() {
        let device = loadedDevice()
        var current = populatedSnapshot(device: device)
        current[2] = workspaceRow(workspace("ws-1"), device: device, isPendingDeletion: true)
        #expect(SidebarOutlineDiff.compute(previous: populatedSnapshot(device: device), current: current) == .rowsChanged(["w:ws-1"]))
    }

    @Test func renamedRuntimeTargetRepaintsOnlyThatTargetRow() {
        let device = loadedDevice()
        var current = populatedSnapshot(device: device)
        current[3] = targetRow(targetItem(key: "terminal:s1", title: "build"), workspaceID: "ws-1", device: device)
        #expect(SidebarOutlineDiff.compute(previous: populatedSnapshot(device: device), current: current) == .rowsChanged(["rt:ws-1:terminal:s1"]))
    }

    @Test func deviceGoingOfflineRepaintsEveryRowOfThatDevice() {
        // Every row under a device is dimmed and tooltipped from that device's load state, so an outage
        // that leaves the rows themselves untouched still has to repaint all of them.
        let offline = SidebarRowDeviceTreatment(loadState: .offline("connection refused"), displayName: "Studio")
        let verdict = SidebarOutlineDiff.compute(previous: populatedSnapshot(device: loadedDevice()), current: populatedSnapshot(device: offline))
        #expect(verdict == .rowsChanged(["d:\(Self.deviceID)", "p:proj-1", "w:ws-1", "rt:ws-1:terminal:s1"]))
    }

    @Test func addedWorkspaceRebuildsTheOutline() {
        let device = loadedDevice()
        var current = populatedSnapshot(device: device)
        current.insert(workspaceRow(workspace("ws-2"), device: device), at: 3)
        #expect(SidebarOutlineDiff.compute(previous: populatedSnapshot(device: device), current: current) == .structureChanged)
    }

    @Test func removedProjectRebuildsTheOutline() {
        let device = loadedDevice()
        let previous = populatedSnapshot(device: device)
        #expect(SidebarOutlineDiff.compute(previous: previous, current: [deviceRow(device)]) == .structureChanged)
    }

    @Test func reorderedRowsRebuildTheOutline() {
        // Same rows, different places: only a rebuild moves a row.
        let device = loadedDevice()
        let previous = [projectRow(project("proj-1"), device: device), projectRow(project("proj-2"), device: device)]
        #expect(SidebarOutlineDiff.compute(previous: previous, current: previous.reversed()) == .structureChanged)
    }

    /// Collapsing a project is a change of shape, not of content: the sidebar's snapshot walk omits the
    /// children of a collapsed project, because a project's collapse state rides in the applied data and
    /// only the wholesale rebuild path re-applies expansion to the outline view.
    @Test func collapsingAProjectRebuildsTheOutline() {
        let device = loadedDevice()
        let expanded = [projectRow(project("proj-1"), device: device), workspaceRow(workspace("ws-1"), device: device)]
        let collapsed = [projectRow(project("proj-1", isCollapsed: true), device: device)]
        #expect(SidebarOutlineDiff.compute(previous: expanded, current: collapsed) == .structureChanged)
    }
}
