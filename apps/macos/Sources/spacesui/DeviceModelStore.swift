import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

/// Owns the device/sidebar data cache: the flattened project and workspace state for every paired
/// device, the local device's identity, and the per-device sidebar sections built from device
/// overviews. Extracted from `AppKitController` as a behavior-preserving move (part of the ongoing
/// decomposition of that type); `AppKitController` holds this as `deviceModel` and sibling
/// sub-controllers reach it as `host.deviceModel`.
@MainActor final class DeviceModelStore {
    var projects: [ProjectSummary] = []
    var workspacesByProject: [String: [WorkspaceSummary]] = [:] {
        didSet {
            invalidateVisibleWorkspacesCache()
            // Flat id -> (projectID, workspace) index, rebuilt alongside workspacesByProject so it can
            // never go stale. Lets findWorkspace(id:) resolve in O(1) instead of scanning every
            // project's workspace list, which matters since it's called from ~26 sites including
            // selection/reload hot paths.
            workspaceIndex = workspacesByProject.reduce(into: [:]) { index, entry in
                for workspace in entry.value { index[workspace.id] = (projectID: entry.key, workspace: workspace) }
            }
            // `SidebarController.rebuildFlatSidebarData()` — the single point every overview-install
            // path (the local snapshot, a remote pull/subscription, a mutation response) funnels
            // through — assigns this property on every call, so it is the nearest reachable proxy for
            // that funnel from this type. See `resolveAwaitingWorkspaceDeletions`.
            resolveAwaitingWorkspaceDeletions()
        }
    }
    private(set) var workspaceIndex: [String: (projectID: String, workspace: WorkspaceSummary)] = [:]
    var workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus] = [:]
    // The macOS app always loads its own local daemon first; these hold that local
    // device and act as the default target when no row is selected. Per-row device
    // context is resolved via deviceID(for…) helpers and the device sections.
    var localDeviceID = SpacesPairedDeviceRecord.localDeviceID
    /// Advances whenever an authoritative local overview is installed, including a mutation response.
    /// Sidebar reloads capture this before their off-main read; a response that lands while that read
    /// is in flight therefore fences the stale snapshot before it can reconcile missing workspaces.
    var localOverviewInstallGeneration = 0
    var localDeviceName = "This Mac"
    var localPairedDevice: SpacesPairedDeviceRecord?
    var deviceSections: [DeviceSection] = []
    var alertsGroups: [AlertsController.AlertsGroup] = []
    var configCache: AppConfig?

    private let invalidateVisibleWorkspacesCache: () -> Void
    private let resolveAwaitingWorkspaceDeletions: () -> Void

    /// The `workspacesByProject` `didSet` above runs three effects, in this fixed order: invalidate the
    /// sidebar's visible-workspaces cache, rebuild `workspaceIndex`, then resolve any deferred workspace
    /// deletions. The order is load-bearing rather than incidental — `resolveAwaitingWorkspaceDeletions`
    /// reads state (via the device sections, which reflect the just-rebuilt index) that must already be
    /// current, so it has to run last; the cache invalidation runs first so nothing reads a stale
    /// visible-workspaces cache while the index is mid-rebuild.
    init(invalidateVisibleWorkspacesCache: @escaping () -> Void, resolveAwaitingWorkspaceDeletions: @escaping () -> Void) {
        self.invalidateVisibleWorkspacesCache = invalidateVisibleWorkspacesCache
        self.resolveAwaitingWorkspaceDeletions = resolveAwaitingWorkspaceDeletions
    }

    struct SidebarDataSnapshot: Sendable {
        let config: AppConfig
        let local: AppKitController.LocalDeviceSidebarSnapshot
    }

    enum SidebarDeviceLoadState: Sendable, Hashable {
        case loading
        case offline(String)
        case loaded

        var isOffline: Bool {
            if case .offline = self { return true }
            return false
        }
    }

    /// One paired device's slice of the sidebar. The sidebar shows every paired
    /// device at once; each section loads independently so a slow or unreachable
    /// device does not block the others.
    struct DeviceSection: Sendable {
        let deviceID: String
        let deviceName: String
        let isLocal: Bool
        var loadState: SidebarDeviceLoadState
        var device: SpacesPairedDeviceRecord?
        var projects: [ProjectSummary] = []
        var workspacesByProject: [String: [WorkspaceSummary]] = [:]
        var workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus] = [:]
        var alertsGroups: [AlertsController.AlertsGroup] = []
        /// Bumped by `overview`'s `didSet` on every reassignment after this section already exists —
        /// once per overview-install event for this device, from whichever path installs it (a local
        /// snapshot refresh, a remote pull/subscription in `SidebarController`, or a mutation response
        /// in this file). A struct's own memberwise init never routes through property observers, so a
        /// section's initial construction leaves this at its default rather than counting as an install.
        ///
        /// `resolveAwaitingWorkspaceDeletions` uses this to tell "fresh evidence for the owning device
        /// arrived" apart from "some other device's refresh re-ran the `workspacesByProject` didSet,
        /// which reread this device's untouched, possibly stale, cached overview" — the bug this guards
        /// against: an offline owning device keeps its last-known overview, and a rebuild triggered by
        /// any other device would otherwise draw a delete verdict from evidence that predates the
        /// delete.
        ///
        /// The local device's section is not mutated in place on an ordinary refresh — it is rebuilt and
        /// assigned whole (`SidebarController.rebuildFlatSidebarData()`), which bypasses `didSet` — so that
        /// path carries the counter forward explicitly via `adoptingOverviewInstallGeneration(from:)`.
        /// Without that, the local counter would reset to zero on every refresh and a deferred delete for a
        /// local workspace would never see fresh evidence at all.
        private(set) var overviewInstallGeneration = 0
        var overview: SpacesDeviceOverviewPayload? { didSet { overviewInstallGeneration += 1 } }

        /// Carries `previous`'s install generation into this freshly built section, counting one new install
        /// when `carriesFreshInstall` says this rebuild is carrying an overview the daemon actually just
        /// returned.
        ///
        /// The caller states that fact rather than letting this infer it from payload equality. A fresh
        /// fetch that happens to be byte-identical to the cached one is real evidence — it is exactly what
        /// a delete that never reached the daemon looks like — and treating it as "nothing happened" would
        /// leave that deferred delete unresolvable for the rest of the run. Conversely an outage rebuild
        /// re-renders the retained overview without asking the daemon anything, and must not count.
        func adoptingOverviewInstallGeneration(from previous: DeviceSection?, carriesFreshInstall: Bool) -> DeviceSection {
            var section = self
            section.overviewInstallGeneration = (previous?.overviewInstallGeneration ?? 0) + (carriesFreshInstall ? 1 : 0)
            return section
        }
        /// Frozen-core handshake read for this device, refreshed alongside the overview. `nil` until
        /// the first successful handshake; drives the per-device compatibility banner and gating.
        var daemonStatus: TerminalServiceDaemonStatus?
        var compatibility: SpacesWireCompatibility?

        /// The label shown for this device everywhere in the UI. The local device always renders as
        /// "Local" regardless of its stored machine name; remote devices show their stored name.
        var displayName: String { isLocal ? "Local" : deviceName }
    }
}
