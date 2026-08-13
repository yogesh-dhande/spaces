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
    /// nil for a generic workspace-less session. Workspace-scoped enumeration must
    /// tolerate nil rather than assume every session belongs to a workspace.
    public var workspaceID: String? { launchConfiguration.workspaceID }
    public var kind: TerminalSessionKind { launchConfiguration.kind }
    /// The session's stable name: the user's rename when set, else the launch-generated name. What the
    /// program inside prints never replaces it; that travels beside it as `liveTitle`.
    public var name: String { TerminalSessionTitle.name(userTitle: launchConfiguration.userTitle, launchTitle: launchConfiguration.title) }
    /// What the program running in this session last reported as its title, nil when it reported none.
    public var liveTitle: String? { TerminalSessionTitle.liveTitle(runtimeState.title) }
    public var effectiveWorkingDirectory: String { runtimeState.workingDirectory ?? launchConfiguration.workingDirectory }
}

public enum TerminalSessionCatalog {
    /// The sessions that currently have a live interactive service, in stored session order.
    ///
    /// Liveness is decided first, from one batched read of every session row and its runtime state,
    /// and only the sessions that survive it are expanded into entries. Ordering the work the other
    /// way round — expanding a session to learn whether it is live — made this cost grow with every
    /// session the device had ever created, and the device-API overview rebuilds it several times a
    /// second. Which sessions are reported is unaffected: the batched read answers the runtime-state
    /// lookup for exactly the rows a per-session read would have answered it for, and every returned
    /// row is still put through `isInteractiveServiceAlive` in full.
    public static func listLiveSessions(fileManager: FileManager = .default) throws -> [TerminalSessionCatalogEntry] {
        try TerminalSessionPersistence.listInteractiveSessionRuntimeStates().filter { isInteractiveServiceAlive(for: $0.runtimeState) }.map {
            session in
            let paths = try TerminalSessionPaths.forStoredSession(id: session.sessionID, rootDirectory: session.rootDirectory)
            let attachmentSnapshot = (try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? .init()
            return TerminalSessionCatalogEntry(
                launchConfiguration: session.launchConfiguration, runtimeState: session.runtimeState, attachmentSnapshot: attachmentSnapshot,
                paths: paths, isControlAvailable: fileManager.fileExists(atPath: paths.controlSocketPath),
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
