import Foundation
import Testing
import spacesdevicecore
import workspacecore

@testable import spacesui

/// Behavior of `DeviceModelStore`, the device/sidebar data cache extracted from `AppKitController`:
/// the fixed effect ordering its `workspacesByProject` `didSet` runs through the two injected hooks,
/// `workspaceIndex`'s derivation from a multi-project `workspacesByProject`, and `DeviceSection`'s
/// `overviewInstallGeneration` bookkeeping.
@MainActor struct DeviceModelStoreTests {
    private func workspace(id: String, deviceID: String = "local") -> WorkspaceSummary {
        WorkspaceSummary(id: id, branch: "feature", dir: "/tmp/\(id)", isRunning: true, isDefault: false, deviceID: deviceID)
    }

    // MARK: - Hook ordering

    /// The three effects `workspacesByProject`'s `didSet` runs — invalidate the visible-workspaces
    /// cache, rebuild `workspaceIndex`, then resolve awaiting workspace deletions — must fire in
    /// exactly that order every time the property is assigned. The resolve closure additionally has to
    /// see the *new* `workspaceIndex`, not a stale one from before the rebuild, since
    /// `resolveAwaitingWorkspaceDeletions` is documented to read state that reflects the just-rebuilt
    /// index.
    @Test func workspacesByProjectAssignmentRunsItsHooksInFixedOrderAndTheResolveHookSeesTheFreshIndex() {
        var events: [String] = []
        var workspaceIndexSeenByResolve: [String]?
        var store: DeviceModelStore!
        store = DeviceModelStore(
            invalidateVisibleWorkspacesCache: { events.append("invalidate") },
            resolveAwaitingWorkspaceDeletions: {
                events.append("resolve")
                workspaceIndexSeenByResolve = store.workspaceIndex.keys.sorted()
            })

        store.workspacesByProject = ["project-1": [workspace(id: "workspace-1")]]

        #expect(events == ["invalidate", "resolve"])
        #expect(workspaceIndexSeenByResolve == ["workspace-1"])
    }

    /// Every reassignment re-runs the full hook sequence, not just the first one.
    @Test func eachReassignmentRunsTheHooksAgain() {
        var events: [String] = []
        let store = DeviceModelStore(
            invalidateVisibleWorkspacesCache: { events.append("invalidate") },
            resolveAwaitingWorkspaceDeletions: { events.append("resolve") })

        store.workspacesByProject = ["project-1": [workspace(id: "workspace-1")]]
        store.workspacesByProject = ["project-1": [workspace(id: "workspace-2")]]

        #expect(events == ["invalidate", "resolve", "invalidate", "resolve"])
    }

    // MARK: - workspaceIndex

    /// `workspaceIndex` flattens every project's workspaces into a single id-keyed lookup, carrying
    /// each workspace's owning project id alongside it.
    @Test func workspaceIndexFlattensMultipleProjectsAndCarriesEachWorkspacesProjectID() {
        let store = DeviceModelStore(invalidateVisibleWorkspacesCache: {}, resolveAwaitingWorkspaceDeletions: {})

        store.workspacesByProject = [
            "project-1": [workspace(id: "workspace-1"), workspace(id: "workspace-2")],
            "project-2": [workspace(id: "workspace-3")],
        ]

        #expect(Set(store.workspaceIndex.keys) == ["workspace-1", "workspace-2", "workspace-3"])
        #expect(store.workspaceIndex["workspace-1"]?.projectID == "project-1")
        #expect(store.workspaceIndex["workspace-2"]?.projectID == "project-1")
        #expect(store.workspaceIndex["workspace-3"]?.projectID == "project-2")
        #expect(store.workspaceIndex["workspace-3"]?.workspace.id == "workspace-3")
    }

    /// Reassigning `workspacesByProject` with a project dropped drops that project's entries from the
    /// index too — the rebuild is a full replacement, not a merge.
    @Test func workspaceIndexIsFullyRebuiltOnEachAssignment() {
        let store = DeviceModelStore(invalidateVisibleWorkspacesCache: {}, resolveAwaitingWorkspaceDeletions: {})

        store.workspacesByProject = ["project-1": [workspace(id: "workspace-1")], "project-2": [workspace(id: "workspace-2")]]
        #expect(Set(store.workspaceIndex.keys) == ["workspace-1", "workspace-2"])

        store.workspacesByProject = ["project-1": [workspace(id: "workspace-1")]]
        #expect(Set(store.workspaceIndex.keys) == ["workspace-1"])
    }

    // MARK: - DeviceSection.overviewInstallGeneration

    private func section(deviceID: String = "local") -> DeviceModelStore.DeviceSection {
        DeviceModelStore.DeviceSection(deviceID: deviceID, deviceName: "Local", isLocal: true, loadState: .loaded)
    }

    /// A struct's own memberwise construction never routes through property observers, so a freshly
    /// built section's generation starts at zero — only a *reassignment* of `overview` after
    /// construction (exercised below) counts as an install.
    @Test func overviewInstallGenerationStartsAtZeroOnMemberwiseConstruction() {
        #expect(section().overviewInstallGeneration == 0)
    }

    /// Each reassignment of `overview` after construction bumps the generation by one, however many
    /// times it happens.
    @Test func overviewInstallGenerationIncrementsOnEachReassignment() {
        var deviceSection = section()

        deviceSection.overview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [])
        #expect(deviceSection.overviewInstallGeneration == 1)

        deviceSection.overview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [])
        #expect(deviceSection.overviewInstallGeneration == 2)
    }

    /// `adoptingOverviewInstallGeneration(from:carriesFreshInstall:)` carries the previous section's
    /// generation forward and adds one only when the rebuild is stated to carry a fresh install —
    /// mirroring `SidebarController.rebuildFlatSidebarData()`'s local-device path, which rebuilds the
    /// section whole (bypassing `didSet`) and must therefore thread the counter through explicitly.
    @Test func adoptingOverviewInstallGenerationCarriesThePreviousValueAndAddsOneOnlyWhenFresh() {
        var previous = section()
        previous.overview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [])
        #expect(previous.overviewInstallGeneration == 1)

        let rebuiltWithFreshInstall = section().adoptingOverviewInstallGeneration(from: previous, carriesFreshInstall: true)
        #expect(rebuiltWithFreshInstall.overviewInstallGeneration == 2)

        let rebuiltWithoutFreshInstall = section().adoptingOverviewInstallGeneration(from: previous, carriesFreshInstall: false)
        #expect(rebuiltWithoutFreshInstall.overviewInstallGeneration == 1)
    }

    /// With no previous section (the device's first-ever rebuild), the adopted generation starts from
    /// zero rather than crashing or defaulting elsewhere.
    @Test func adoptingOverviewInstallGenerationWithNoPreviousSectionStartsFromZero() {
        let rebuiltWithFreshInstall = section().adoptingOverviewInstallGeneration(from: nil, carriesFreshInstall: true)
        #expect(rebuiltWithFreshInstall.overviewInstallGeneration == 1)

        let rebuiltWithoutFreshInstall = section().adoptingOverviewInstallGeneration(from: nil, carriesFreshInstall: false)
        #expect(rebuiltWithoutFreshInstall.overviewInstallGeneration == 0)
    }
}
