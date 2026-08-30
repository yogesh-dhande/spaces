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

    /// This entry with its reported title replaced by `title`, for overlaying a live core's title onto a
    /// DB-derived entry. Every other field is carried through untouched.
    func withLiveTitle(_ title: String?) -> TerminalSessionCatalogEntry {
        var state = runtimeState
        state.title = title
        return TerminalSessionCatalogEntry(
            launchConfiguration: launchConfiguration, runtimeState: state, attachmentSnapshot: attachmentSnapshot, paths: paths,
            isControlAvailable: isControlAvailable, isSubscriptionAvailable: isSubscriptionAvailable)
    }
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
            // Catalog entries exist to be reported off-device (the Device API overview rebuilds this
            // several times a second), so they carry live rows only. See
            // `TerminalSessionAttachmentSnapshot.liveWireProjection`.
            let attachmentSnapshot = ((try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? .init()).liveWireProjection()
            return TerminalSessionCatalogEntry(
                launchConfiguration: session.launchConfiguration, runtimeState: session.runtimeState, attachmentSnapshot: attachmentSnapshot,
                paths: paths, isControlAvailable: fileManager.fileExists(atPath: paths.controlSocketPath),
                isSubscriptionAvailable: fileManager.fileExists(atPath: paths.subscriptionSocketPath))
        }
    }

    /// Replaces each DB-derived summary's title with the one the live core reports, for every session a
    /// core in this process hosts. The stored row does not track title changes (see the persist signature
    /// in the session core), so the core is the authority and a listing built from rows would otherwise
    /// report whatever title the row last happened to be written with.
    ///
    /// The summary sibling of `mergingLiveInMemorySessions`' title overlay, kept beside it so the daemon's
    /// RPC listing and the Device API overview apply one rule rather than two copies of it. Unlike that
    /// merge this only overlays; appending in-memory-only sessions stays with the caller, whose summaries
    /// carry fields this has no view of.
    public static func overlayingLiveTitles(_ summaries: [TerminalServiceSessionSummary], liveInMemory: [TerminalServiceSessionSummary])
        -> [TerminalServiceSessionSummary]
    {
        guard !liveInMemory.isEmpty else { return summaries }
        let liveByID = Dictionary(liveInMemory.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return summaries.map { summary in
            guard let live = liveByID[summary.id] else { return summary }
            var overlaid = summary
            // Both titles move, and each from its own counterpart. The summary carries the runtime state it
            // was built from and a consumer may read either, so moving only the outer one would ship a
            // response that contradicts itself. They are not the same value: `title` is the effective one
            // (`runtimeState.title ?? launchConfiguration.title`) while the nested one is the program's raw
            // report, nil when it never set a title. Copying the effective title into the raw field would
            // fold the launch title in and make an untitled session indistinguishable from one that named
            // itself after its own launch title.
            overlaid.title = live.title
            overlaid.runtimeState?.title = live.runtimeState?.title
            return overlaid
        }
    }

    /// Merges the daemon's live in-memory session entries into a DB-derived catalog listing.
    /// DB-derived entries come first in their stored order; in-memory entries are appended only when
    /// interactive and not already present, mirroring `SpacesdMain.listSessionsOffMain()`'s in-memory
    /// summary merge. In-memory cores are the authority for a session's existence: lifecycle rows are
    /// write-behind on the per-core persistence queue, so without this merge a freshly created live
    /// session would vanish from a listing (and, for the Device API overview specifically, its terminal
    /// window would render as ended) until its queued writes commit.
    public static func mergingLiveInMemorySessions(_ dbSessions: [TerminalSessionCatalogEntry], inMemory: [TerminalSessionCatalogEntry])
        -> [TerminalSessionCatalogEntry]
    {
        let inMemoryByID = Dictionary(inMemory.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        // A live session's reported title is owned by its in-memory core, which advances `currentTitle` the
        // moment the program reports one. The DB row is a mirror that no longer tracks title changes (see
        // `runtimeStateSignature`), so a session present in both takes its live title from the core. Only the
        // title is overlaid: the DB entry's other fields are derived alongside filesystem state (attachment
        // snapshot, control/subscription socket presence) that the in-memory entry does not recompute.
        var merged = dbSessions.map { entry -> TerminalSessionCatalogEntry in
            guard let live = inMemoryByID[entry.sessionID] else { return entry }
            return entry.withLiveTitle(live.runtimeState.title)
        }
        let knownSessionIDs = Set(dbSessions.map(\.sessionID))
        for entry in inMemory where isInteractiveServiceAlive(for: entry.runtimeState) && !knownSessionIDs.contains(entry.sessionID) {
            merged.append(entry)
        }
        return merged
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
