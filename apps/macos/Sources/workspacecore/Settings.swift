import Foundation

public enum SettingsKey {
    public static let appPortRangeStart = "app_port_range_start"
    public static let appPortRangeEnd = "app_port_range_end"
    public static let appRouterPort = "app_router_port"
    /// The release channel a self-updating Linux daemon follows (`stable` or `prerelease`).
    public static let daemonUpdateChannel = "daemon_update_channel"
}
