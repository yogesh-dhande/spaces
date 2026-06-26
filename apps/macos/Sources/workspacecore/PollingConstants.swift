import Foundation

public enum PollingConstants {
    public static let browserWindowScanDebounceInterval: TimeInterval = 10

    public static let workspaceWindowRefreshInterval: TimeInterval = 10

    /// Freshness window that throttles remote-device overview fetches when the
    /// sidebar reloads from local activity. Not a poll cadence; the sidebar reloads
    /// from `IPCNotification.databaseDidChange` posted by database writers.
    public static let remoteOverviewFreshnessInterval: TimeInterval = 30

    public static let statusCheckDefaultInterval: Int = 60

    public static let statusCheckDefaultTimeout: Int = 10
}
