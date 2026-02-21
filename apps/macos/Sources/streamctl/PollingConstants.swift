import Foundation

public enum PollingConstants {
    public static let browserWindowScanDebounceInterval: TimeInterval = 10

    public static let workspaceWindowRefreshInterval: TimeInterval = 10

    public static let worktreeDiscoveryInterval: TimeInterval = 30
    
    public static let processStatusCheckInterval: TimeInterval = 10
    
    public static let statusCheckDefaultInterval: Int = 60
    
    public static let statusCheckDefaultTimeout: Int = 10
}
