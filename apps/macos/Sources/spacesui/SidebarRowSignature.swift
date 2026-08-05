import Foundation
import workspacecore

/// Everything one sidebar outline row's cell renders, captured as a comparable value.
///
/// The sidebar signs every row on each applied device overview and compares the result against the
/// previous build (see `SidebarOutlineDiff`) to decide which rows have to be rebuilt. A signature must
/// therefore carry every input its cell builder reads, or a change to that input would repaint nothing.
/// It deliberately carries whole `ProjectSummary` / `WorkspaceSummary` / `WorkspaceRuntimeStatus` values
/// rather than the handful of fields the cells read today, so a cell that starts rendering another field
/// cannot silently go stale.
///
/// Selection is the one rendered input left out: a selection move already reloads exactly the rows it
/// affects (`refreshSidebarSelectionRows`), and a rebuilt cell reads the live selection, so folding it in
/// here would only add redundant reloads.
enum SidebarRowSignature: Hashable, Sendable {
    case device(SidebarDeviceRowSignature)
    case project(SidebarProjectRowSignature)
    case emptyProject(SidebarEmptyProjectRowSignature)
    case workspace(SidebarWorkspaceRowSignature)
    case runtimeTarget(SidebarRuntimeTargetRowSignature)
}

/// The owning device's contribution to every row underneath it. `dimmedForUnreachableDevice` reads that
/// device's load state for the row's opacity and its name for the offline tooltip, so one device going
/// offline changes how every one of its rows renders — which is why this rides in each of them.
/// A `nil` load state is a row whose device has no section at all, the case the cell leaves undimmed.
struct SidebarRowDeviceTreatment: Hashable, Sendable {
    let loadState: AppKitController.SidebarDeviceLoadState?
    let displayName: String?
}

/// A device header row: the section caption and, where the state is actionable, the button that both
/// reports and recovers it. `offersRetry` and `isUpdatePending` are the two remaining inputs
/// `SidebarDeviceSectionStatus.resolve` takes beyond the load state, and `compatibilityActionTitle` is
/// the whole compatibility branch the cell takes ahead of that caption (nil when the device is
/// compatible, otherwise the button's title).
struct SidebarDeviceRowSignature: Hashable, Sendable {
    let displayName: String
    let loadState: AppKitController.SidebarDeviceLoadState
    let compatibilityActionTitle: String?
    let isLocal: Bool
    let offersRetry: Bool
    let isUpdatePending: Bool
}

/// A project row. A non-git project's row stands in for its single workspace, so it also renders that
/// workspace's run state (the tinted folder), its delete-in-flight spinner, and — through
/// `isExpandable` — whether that workspace has any runtime targets to disclose.
struct SidebarProjectRowSignature: Hashable, Sendable {
    let device: SidebarRowDeviceTreatment
    let project: ProjectSummary
    let standInWorkspace: WorkspaceSummary?
    let standInRuntimeStatus: WorkspaceRuntimeStatus?
    let standInIsPendingDeletion: Bool
    let isExpandable: Bool
}

/// The "No workspaces yet" placeholder under an empty git project. Its text and layout are fixed, so the
/// owning device's dimming is the only thing that changes how it renders.
struct SidebarEmptyProjectRowSignature: Hashable, Sendable { let device: SidebarRowDeviceTreatment }

/// A workspace row: its name, its run-state dot and warning icon (both read out of the runtime status),
/// the spinner and stripped controls of a delete in flight, and the disclosure chevron — which exists
/// only when the workspace has runtime targets and points at `isExpanded`.
struct SidebarWorkspaceRowSignature: Hashable, Sendable {
    let device: SidebarRowDeviceTreatment
    let workspace: WorkspaceSummary
    let runtimeStatus: WorkspaceRuntimeStatus?
    let isPendingDeletion: Bool
    let isExpanded: Bool
    let hasRuntimeTargets: Bool
}

/// A runtime-target row. The item carries everything the row draws (title, secondary detail, kind icon,
/// run state); `nestedUnderWorkspace` is its indent, and `isRenaming` is the inline editor the row swaps
/// its title for.
struct SidebarRuntimeTargetRowSignature: Hashable, Sendable {
    let device: SidebarRowDeviceTreatment
    let item: SidebarRuntimeTargetItem
    let nestedUnderWorkspace: Bool
    let isRenaming: Bool
}
