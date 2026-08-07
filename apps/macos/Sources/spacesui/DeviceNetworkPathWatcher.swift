import Foundation
import Network

/// One observed network path, reduced to the facts that decide whether the addresses this Mac can reach
/// may have changed: whether the path can carry traffic at all, which interfaces back it, and which
/// routers it goes through.
///
/// Status and interfaces alone are not enough. Moving between two Wi-Fi networks, or waking on a
/// different one, can leave the status satisfied and the interface set `{en0}` byte-for-byte unchanged
/// while every address on the far side has changed. The gateways are what separate those cases: a
/// different network is reached through a different router. They are reduced to their descriptions
/// rather than compared as endpoints, because the value here is only ever tested for equality against
/// the previous observation.
struct DeviceNetworkPathSnapshot: Equatable, Sendable {
    let isSatisfied: Bool
    let interfaceNames: Set<String>
    let gateways: Set<String>

    init(isSatisfied: Bool, interfaceNames: Set<String>, gateways: Set<String> = []) {
        self.isSatisfied = isSatisfied
        self.interfaceNames = interfaceNames
        self.gateways = gateways
    }

    init(path: NWPath) {
        self.init(
            isSatisfied: path.status == .satisfied, interfaceNames: Set(path.availableInterfaces.map(\.name)),
            gateways: Set(path.gateways.map(\.debugDescription)))
    }
}

/// Decides which observed paths are a change worth re-racing every device's addresses for.
///
/// `NWPathMonitor` delivers the current path immediately on start and then repeats a path whenever any
/// property Spaces does not read changes, so acting on every callback would re-race every paired device
/// at launch and again on unrelated churn. Only a path that differs from the last one observed counts,
/// and the very first path is the baseline rather than a change. Kept separate from the monitor so the
/// rule is directly testable without Network.framework.
struct DeviceNetworkPathChangeFilter {
    private var lastObserved: DeviceNetworkPathSnapshot?

    mutating func shouldReact(to snapshot: DeviceNetworkPathSnapshot) -> Bool {
        defer { lastObserved = snapshot }
        guard let lastObserved else { return false }
        return lastObserved != snapshot
    }
}

/// Watches this Mac's own network path and reports meaningful changes on the main actor.
///
/// A paired device is reachable at more than one address, and which of them works depends entirely on
/// where this Mac currently is: leaving a network, joining a different one, or toggling Tailscale
/// silently invalidates the address every resolver just proved. Nothing else notices promptly: a stream parked
/// on a dead path waits out its TCP keepalive, and a device already offline waits out its reconnect
/// backoff. This is what turns "the network moved" into an immediate re-race.
///
/// Holds no UI. Lifecycle is owned by the sidebar alongside the reachability watchdog, which is what
/// bounds it to the window where device subscriptions are live.
@MainActor final class DeviceNetworkPathWatcher {
    private var monitor: NWPathMonitor?
    private var filter = DeviceNetworkPathChangeFilter()
    private let queue = DispatchQueue(label: "spaces.device.network.path")

    /// Starts monitoring, calling `onChange` on the main actor for each meaningful path change. A second
    /// start while already monitoring is ignored, so a repeated services start cannot stack monitors.
    func start(onChange: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = DeviceNetworkPathSnapshot(path: path)
            Task { @MainActor in
                guard let self, self.filter.shouldReact(to: snapshot) else { return }
                onChange()
            }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    /// Stops monitoring and forgets the observed baseline, so a later start treats its first path as a
    /// baseline again rather than as a change against whatever the network looked like last time.
    func stop() {
        monitor?.cancel()
        monitor = nil
        filter = DeviceNetworkPathChangeFilter()
    }
}
