import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public struct TerminalSessionCatalogEntry: Sendable, Equatable {
    public let launchConfiguration: TerminalSessionLaunchConfiguration
    public let runtimeState: TerminalSessionRuntimeState
    public let attachmentSnapshot: TerminalSessionAttachmentSnapshot
    public let paths: TerminalSessionPaths
    public let isControlAvailable: Bool
    public let isSubscriptionAvailable: Bool

    public init(
        launchConfiguration: TerminalSessionLaunchConfiguration, runtimeState: TerminalSessionRuntimeState,
        attachmentSnapshot: TerminalSessionAttachmentSnapshot, paths: TerminalSessionPaths, isControlAvailable: Bool, isSubscriptionAvailable: Bool
    ) {
        self.launchConfiguration = launchConfiguration
        self.runtimeState = runtimeState
        self.attachmentSnapshot = attachmentSnapshot
        self.paths = paths
        self.isControlAvailable = isControlAvailable
        self.isSubscriptionAvailable = isSubscriptionAvailable
    }

    public var sessionID: String { launchConfiguration.sessionID }
    public var workspaceID: String { launchConfiguration.workspaceID }
    public var kind: TerminalSessionKind { launchConfiguration.kind }
    /// A manual rename (userTitle) wins over the runtime title, which Ghostty set_title events
    /// keep rewriting; the launch-time title is the fallback before either exists.
    public var effectiveTitle: String { launchConfiguration.userTitle ?? runtimeState.title ?? launchConfiguration.title }
    public var effectiveWorkingDirectory: String { runtimeState.workingDirectory ?? launchConfiguration.workingDirectory }
}

public enum TerminalSessionCatalog {
    public static func listLiveSessions(fileManager: FileManager = .default) throws -> [TerminalSessionCatalogEntry] {
        try TerminalSessionPersistence.listKnownSessions(fileManager: fileManager).compactMap { knownSession in
            let launchConfiguration = knownSession.launchConfiguration
            let paths = knownSession.paths
            guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { return nil }
            guard isInteractiveServiceAlive(for: runtimeState) else { return nil }
            let attachmentSnapshot = (try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? .init()
            return TerminalSessionCatalogEntry(
                launchConfiguration: launchConfiguration, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot, paths: paths,
                isControlAvailable: fileManager.fileExists(atPath: paths.controlSocketPath),
                isSubscriptionAvailable: fileManager.fileExists(atPath: paths.subscriptionSocketPath))
        }
    }

    public static func isInteractiveServiceAlive(for runtimeState: TerminalSessionRuntimeState) -> Bool {
        guard runtimeState.state.isInteractive else { return false }
        return isProcessAlive(pid: runtimeState.servicePID)
    }

    private static func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}
