import Foundation

public enum PollingConstants {
    public static let browserWindowScanDebounceInterval: TimeInterval = 10

    public static let workspaceWindowRefreshInterval: TimeInterval = 10

    /// Freshness window that throttles remote-device overview fetches when the
    /// sidebar reloads from local activity. Not a poll cadence; the sidebar reloads
    /// from `IPCNotification.databaseDidChange` posted by database writers.
    public static let remoteOverviewFreshnessInterval: TimeInterval = 30

    /// Cadence at which the sidebar re-reconciles device reachability: reopening subscriptions that
    /// have none, re-pulling the overview of a device stuck offline, and re-probing an offline local
    /// daemon. The floor under event-driven recovery, not the mechanism it usually recovers by.
    public static let deviceReachabilityWatchdogInterval: TimeInterval = 15

    public static let statusCheckDefaultInterval: Int = 60

    public static let statusCheckDefaultTimeout: Int = 10
}
