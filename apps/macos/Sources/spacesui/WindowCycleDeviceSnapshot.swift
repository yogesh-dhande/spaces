import Foundation
import spacesdevicecore

/// One device's slice of the input a cross-device cycle mode is built from: the device's id, the
/// overview the sidebar last installed for it, and whether the sidebar currently reaches that device.
struct WindowCycleDeviceSnapshot: Sendable {
    let deviceID: String
    let overview: SpacesDeviceOverviewPayload
    /// Mirrors `DeviceModelStore.DeviceSection.loadState == .loaded`, the same flag the sidebar uses to
    /// grey out an offline device's row. The device model keeps an offline device's last overview
    /// rather than clearing it, so `overview` alone cannot tell a live device from one the sidebar can
    /// no longer reach; `WindowCycleModeTargets.targets(...)` reads this to keep a stale device's
    /// agents, and Open sessions' browser sessions, out of a cross-device rotation unless their pane
    /// is already open. Defaults to `true` so every fixture that is not exercising offline behavior
    /// can omit it.
    let isReachable: Bool
    /// Mirrors `DeviceModelStore.DeviceSection.isLocal`. A local workspace's browser sessions focus
    /// through this Mac's Chrome without the daemon (`WindowFocusController`'s `.openURL` case takes
    /// the non-remote branch and calls `focusLocalChromeTab` directly), so an outage of the local
    /// `spacesd` does not take them out of `Open sessions` the way it takes a remote device's (see
    /// `WindowCycleModeTargets.openSessionTargets`). Defaults to `false` so fixtures modelling remote
    /// devices can omit it.
    let isLocal: Bool

    init(deviceID: String, overview: SpacesDeviceOverviewPayload, isReachable: Bool = true, isLocal: Bool = false) {
        self.deviceID = deviceID
        self.overview = overview
        self.isReachable = isReachable
        self.isLocal = isLocal
    }
}
