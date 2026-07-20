import Foundation

/// Reclaims the disk and rows of terminal sessions the product no longer shows.
///
/// A session's transcript (`output.log`), directory, and persisted final-render row survive `terminate`
/// on purpose: an ENDED session whose pane is still visible replays that transcript for scrollback (#181),
/// and an exited process/agent row keeps its ended pane reopenable. So the transcript must outlive the
/// process — but not the product's memory of the session. This collector is the single daemon-owned door
/// that removes a session's footprint, and it fires only when the session is provably gone from the
/// product:
///  1. it is not interactive and its service process is not alive (ended/failed, not live);
///  2. it has no live attachment, so no client is currently showing its ended pane; and
///  3. no `running_processes`/`agent_sessions`/`runtime_targets` row references it, so it is absent from
///     every device overview and no client can reconstruct its pane.
///
/// Deleting a session's referencing rows (e.g. `finalizeAgentRow`'s `.destroyed` path removing the agent
/// row, or process/window removal) is thus what makes a session collectable; this pass is the executor
/// that reclaims it on the daemon's lifecycle tick. Pre-existing accumulated sessions are collected the
/// same way, so no migration is needed.
public enum TerminalSessionGarbageCollector {
    /// Runs one collection pass over every known session. `activeSessionIDs` are sessions the daemon still
    /// owns in memory (live cores) and never collects. `isReferencedByProduct` reports whether a session
    /// still has a product row keeping it visible. Returns the IDs of the sessions purged.
    ///
    /// A single session's purge failure (an undeletable directory — e.g. a permissions error or a busy
    /// file handle — or a `TerminalSessionPaths.forSession` failure) is contained to that session: it is
    /// reported through `onPurgeFailure` and left for the next sweep to retry, and the loop continues to
    /// the remaining sessions. Sessions are collected in a stable order (`listKnownSessions` orders by
    /// `created_at`, then `session_id`) and this sweep reruns on a fixed cadence, so without containment
    /// one permanently-undeletable session would block every session ordered after it forever. This
    /// collector stays pure (no I/O beyond the persistence calls it exists to make): it reports failures
    /// through the callback rather than logging them itself, matching the closure-injection style already
    /// used for `isReferencedByProduct`, and the daemon call site — which already logs the outer sweep
    /// failure to stderr — does the actual logging.
    ///
    /// A `listKnownSessions` failure still aborts the whole call: with no session list, there is nothing
    /// to iterate or retry.
    @discardableResult
    public static func collectRemovedSessions(
        activeSessionIDs: Set<String>, isReferencedByProduct: (String) throws -> Bool, fileManager: FileManager = .default,
        now: Date = Date(), onPurgeFailure: (String, any Error) -> Void = { _, _ in }
    ) throws -> [String] {
        var purged: [String] = []
        for launchConfiguration in try TerminalSessionPersistence.listKnownSessions(fileManager: fileManager) {
            let sessionID = launchConfiguration.sessionID
            guard !activeSessionIDs.contains(sessionID) else { continue }
            do {
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                // No runtime state yet means the session is mid-creation (config written, runtime not); leave it.
                guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { continue }
                guard !isSessionShown(runtimeState: runtimeState, paths: paths, now: now) else { continue }
                guard !((try? isReferencedByProduct(sessionID)) ?? true) else { continue }
                try TerminalSessionPersistence.purgeSession(paths: paths, fileManager: fileManager)
                purged.append(sessionID)
            } catch {
                onPurgeFailure(sessionID, error)
            }
        }
        return purged
    }

    /// Whether the product is currently showing this session's pane: it is still interactive with a live
    /// service, or a client holds a live attachment to its (possibly ended) pane. Either way its transcript
    /// is in use and must not be collected. `TerminalSessionAttachmentSnapshot.liveAttachments` is the same
    /// lease-aware rule the reaper and clients use, so an expired remote viewer never keeps a session pinned.
    /// A failed attachment read is treated as "shown" (fails closed), the same way the caller's
    /// `isReferencedByProduct` check does: this is the only signal that a client currently holds the
    /// session's ended pane, so guessing "no attachments" on a read failure risks purging a session someone
    /// is actively viewing. A false "shown" only defers collection to the next sweep, which costs nothing.
    static func isSessionShown(runtimeState: TerminalSessionRuntimeState, paths: TerminalSessionPaths, now: Date) -> Bool {
        if TerminalSessionCatalog.isInteractiveServiceAlive(for: runtimeState) { return true }
        guard let liveAttachments = try? TerminalSessionPersistence.liveAttachments(paths: paths, now: now) else { return true }
        return !liveAttachments.isEmpty
    }
}
