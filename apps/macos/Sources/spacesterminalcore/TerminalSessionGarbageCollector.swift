import Foundation

/// Reclaims the disk and rows of terminal sessions the product no longer needs.
///
/// A session's transcript (`output.log`), directory, and persisted final-render row survive `terminate`
/// on purpose: an ENDED session whose pane is still visible replays that transcript for scrollback (#181),
/// and an exited process/agent row keeps its ended pane reopenable. So the transcript must outlive the
/// process — but not indefinitely. This collector is the single daemon-owned door that removes a session's
/// footprint, and it retires a session through three tiers, all fail-closed (any doubt defers to the next
/// sweep rather than deleting):
///
///  1. Already gone from the product. A session that is not shown (not interactive-alive, no live
///     attachment) and has no referencing product row is released and then purged outright — deleting a
///     session's rows (e.g. `finalizeAgentRow`'s `.destroyed` path, or process/window removal) is what
///     makes it collectable, and this is the executor. The release runs first so the session's own
///     subscriber standing (its queued inbound notices and outgoing watch edges — state with no foreign
///     key to `terminal_sessions` and not counted by `isReferencedByProduct`) is retired regardless of
///     which path dropped the product rows; interactive closes already retire it themselves, so the call
///     is a no-op in that case.
///  2. Aged out. A session that is still referenced but ended (`.exited`/`.failed`) longer than
///     `endedSessionMaxAge` ago has kept its ended pane reopenable for the full retention window; its
///     product rows are released via `releaseExpiredReferences`, and if that clears the last reference
///     the session is purged. The 7-day clock is the session's own end time (`exitedAt`), not any
///     per-row timestamp. If the release does not clear every reference, the session is left for the
///     next sweep (fail closed, no error).
///  3. Over budget. If the aggregate on-disk size of all ended sessions still exceeds
///     `endedTranscriptByteBudget` after the age pass, the collector evicts oldest-ended-first — via the
///     same release→recheck→purge path — even for sessions younger than the age limit, until the total
///     is back under budget or no evictable session remains. Shown/attached ended sessions still count
///     toward the total but are never evicted; a session whose end time cannot be resolved is never
///     evicted either. If the total is still over budget once every eligible session has been evicted,
///     that residual is reported through `onBudgetExceeded` for the daemon to log.
///
/// Pre-existing accumulated sessions are collected the same way, so no migration is needed, and the first
/// sweep after deploy mass-expires the whole backlog in one pass.
public enum TerminalSessionGarbageCollector {
    /// Runs one collection pass over every known session. `activeSessionIDs` are sessions the daemon still
    /// owns in memory (live cores) and never collects. `isReferencedByProduct` reports whether a session
    /// still has a product row keeping it visible; `releaseExpiredReferences` deletes those product rows for
    /// an expired/over-budget session (there is no default — every caller must decide how the product side
    /// releases). It also runs immediately before every purge, including tier 1's already-unreferenced case,
    /// so the invariant "a purged session has no surviving subscriber state" holds no matter which tier
    /// retires it. `onBudgetExceeded` reports the residual ended-session byte total when it cannot be brought
    /// under `endedTranscriptByteBudget`. Returns the IDs of the sessions purged.
    ///
    /// A single session's purge failure (an undeletable directory — e.g. a permissions error or a busy
    /// file handle — a `TerminalSessionPaths.forSession` failure, or a throwing `releaseExpiredReferences`)
    /// is contained to that session: it is reported through `onPurgeFailure` and left for the next sweep to
    /// retry, and the loop continues to the remaining sessions. Sessions are collected in a stable order
    /// (`listKnownSessions` orders by `created_at`, then `session_id`) and this sweep reruns on a fixed
    /// cadence, so without containment one permanently-undeletable session would block every session ordered
    /// after it forever. This collector stays pure (no I/O beyond the persistence and filesystem calls it
    /// exists to make): it reports failures and the over-budget residual through callbacks rather than
    /// logging them itself, matching the closure-injection style already used for `isReferencedByProduct`,
    /// and the daemon call site — which already logs the outer sweep failure to stderr — does the logging.
    ///
    /// A `listKnownSessions` failure still aborts the whole call: with no session list, there is nothing
    /// to iterate or retry.
    @discardableResult
    public static func collectRemovedSessions(
        activeSessionIDs: Set<String>, isReferencedByProduct: (String) throws -> Bool,
        releaseExpiredReferences: (String) throws -> Void, retentionPolicy: TerminalSessionRetentionPolicy = .standard,
        fileManager: FileManager = .default, now: Date = Date(), onPurgeFailure: (String, any Error) -> Void = { _, _ in },
        onBudgetExceeded: (Int64) -> Void = { _ in }
    ) throws -> [String] {
        var purged: [String] = []
        // Ended sessions that survive the age pass and remain on disk. Tracked (including shown/attached
        // ones) so the byte-budget backstop can weigh the full ended footprint, not just what it may evict.
        var endedOnDisk: [EndedSession] = []
        let expiryCutoff = now.addingTimeInterval(-retentionPolicy.endedSessionMaxAge)

        for launchConfiguration in try TerminalSessionPersistence.listKnownSessions(fileManager: fileManager) {
            let sessionID = launchConfiguration.sessionID
            guard !activeSessionIDs.contains(sessionID) else { continue }
            do {
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                // No runtime state yet means the session is mid-creation (config written, runtime not); leave it.
                guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { continue }
                let isShown = isSessionShown(runtimeState: runtimeState, paths: paths, now: now)
                let isEnded = !runtimeState.state.isInteractive

                // Tier 1: a shown session is never collected; if ended it still counts toward the budget total.
                if isShown {
                    if isEnded { endedOnDisk.append(EndedSession(sessionID: sessionID, paths: paths, runtimeState: runtimeState, isShown: true)) }
                    continue
                }

                // Tier 1: an unreferenced, not-shown session is released, then purged outright. The release
                // must run even though the product side is already unreferenced: it is what retires the
                // session's own subscriber standing (queued inbound notices, outgoing watch edges), which
                // survives a product-row drop that bypassed the interactive close chokepoints. For an
                // already-fully-released session this is a no-op, so it is safe to call unconditionally.
                if !((try? isReferencedByProduct(sessionID)) ?? true) {
                    try releaseExpiredReferences(sessionID)
                    try TerminalSessionPersistence.purgeSession(paths: paths, fileManager: fileManager)
                    purged.append(sessionID)
                    continue
                }

                // Tier 2: a still-referenced ended session past the age limit releases its rows, then purges
                // only if that cleared the last reference. Still referenced → leave for next sweep (fail closed).
                if isEnded, let endedAt = endedAt(runtimeState: runtimeState, paths: paths, fileManager: fileManager), endedAt <= expiryCutoff {
                    if try releaseAndPurgeIfUnreferenced(
                        sessionID: sessionID, paths: paths, isReferencedByProduct: isReferencedByProduct,
                        releaseExpiredReferences: releaseExpiredReferences, fileManager: fileManager)
                    {
                        purged.append(sessionID)
                        continue
                    }
                }

                // Survived the age pass and remains on disk; if ended it is weighed by the budget backstop.
                if isEnded { endedOnDisk.append(EndedSession(sessionID: sessionID, paths: paths, runtimeState: runtimeState, isShown: false)) }
            } catch {
                onPurgeFailure(sessionID, error)
            }
        }

        evictOverBudget(
            endedOnDisk: endedOnDisk, purged: &purged, retentionPolicy: retentionPolicy, isReferencedByProduct: isReferencedByProduct,
            releaseExpiredReferences: releaseExpiredReferences, fileManager: fileManager, onPurgeFailure: onPurgeFailure,
            onBudgetExceeded: onBudgetExceeded)

        return purged
    }

    /// An ended session that remains on disk after the age pass, retained so the byte-budget backstop can
    /// size the full ended footprint. `isShown` sessions count toward the total but are never evicted.
    private struct EndedSession {
        let sessionID: String
        let paths: TerminalSessionPaths
        let runtimeState: TerminalSessionRuntimeState
        let isShown: Bool
    }

    /// Releases a session's product rows and purges it only if that cleared the last reference. Returns
    /// whether the session was purged. If a reference survives the release, nothing is deleted and `false`
    /// is returned, so the session is retried on the next sweep (fail closed). Shared by the age pass and
    /// the budget backstop so both retire a session through the identical release→recheck→purge path.
    private static func releaseAndPurgeIfUnreferenced(
        sessionID: String, paths: TerminalSessionPaths, isReferencedByProduct: (String) throws -> Bool,
        releaseExpiredReferences: (String) throws -> Void, fileManager: FileManager
    ) throws -> Bool {
        try releaseExpiredReferences(sessionID)
        guard !((try? isReferencedByProduct(sessionID)) ?? true) else { return false }
        try TerminalSessionPersistence.purgeSession(paths: paths, fileManager: fileManager)
        return true
    }

    /// The byte-budget backstop (tier 3). Sums the on-disk size of every ended session still present after
    /// the age pass — including shown/attached ones, which reflect real disk pressure even though they are
    /// never evicted — and, if that exceeds `endedTranscriptByteBudget`, evicts eligible sessions
    /// oldest-ended-first via the shared release→recheck→purge path until the total is back under budget or
    /// no evictable session remains. A session is eligible only if it is not shown and its end time is
    /// resolvable (an unresolvable end time cannot be ordered against others, so such a session is never
    /// evicted first — fail closed). A per-session eviction failure is contained through `onPurgeFailure`
    /// and its bytes stay counted. If the total is still over budget once candidates are exhausted, the
    /// residual is reported through `onBudgetExceeded`.
    private static func evictOverBudget(
        endedOnDisk: [EndedSession], purged: inout [String], retentionPolicy: TerminalSessionRetentionPolicy,
        isReferencedByProduct: (String) throws -> Bool, releaseExpiredReferences: (String) throws -> Void, fileManager: FileManager,
        onPurgeFailure: (String, any Error) -> Void, onBudgetExceeded: (Int64) -> Void
    ) {
        guard !endedOnDisk.isEmpty else { return }
        let sized = endedOnDisk.map { session -> (session: EndedSession, size: Int64, endedAt: Date?) in
            (session, directorySizeInBytes(session.paths.rootDirectory, fileManager: fileManager),
             endedAt(runtimeState: session.runtimeState, paths: session.paths, fileManager: fileManager))
        }
        var total = sized.reduce(Int64(0)) { $0 + $1.size }
        guard total > retentionPolicy.endedTranscriptByteBudget else { return }

        let candidates = sized.filter { !$0.session.isShown && $0.endedAt != nil }.sorted { $0.endedAt! < $1.endedAt! }
        for candidate in candidates {
            guard total > retentionPolicy.endedTranscriptByteBudget else { break }
            do {
                if try releaseAndPurgeIfUnreferenced(
                    sessionID: candidate.session.sessionID, paths: candidate.session.paths, isReferencedByProduct: isReferencedByProduct,
                    releaseExpiredReferences: releaseExpiredReferences, fileManager: fileManager)
                {
                    purged.append(candidate.session.sessionID)
                    total -= candidate.size
                }
            } catch {
                onPurgeFailure(candidate.session.sessionID, error)
            }
        }

        if total > retentionPolicy.endedTranscriptByteBudget { onBudgetExceeded(total) }
    }

    /// Resolves the session's end instant used for age-expiry and eviction ordering. The runtime
    /// `exitedAt` (written when the process exits) is authoritative; it is parsed with the both-format
    /// timestamp parser so a fractional-seconds stamp from a Linux daemon parses as well as a whole-second
    /// one from macOS. When `exitedAt` is missing or unparseable, the newest of the session directory's and
    /// `output.log`'s modification times stands in, since either is touched around the session's final
    /// activity. If none of those is readable the end time is unresolvable and the session never
    /// age-expires and is never evicted (fail closed) — it can only ever leave via tier 1.
    private static func endedAt(runtimeState: TerminalSessionRuntimeState, paths: TerminalSessionPaths, fileManager: FileManager) -> Date? {
        if let exitedAt = runtimeState.exitedAt, let parsed = GhosttyRemoteSessionStateTimestamp.date(from: exitedAt) { return parsed }
        let directoryModifiedAt = modificationDate(ofPath: paths.rootDirectory, fileManager: fileManager)
        let outputModifiedAt = modificationDate(ofPath: paths.outputPath, fileManager: fileManager)
        switch (directoryModifiedAt, outputModifiedAt) {
        case let (directory?, output?): return max(directory, output)
        case let (directory?, nil): return directory
        case let (nil, output?): return output
        case (nil, nil): return nil
        }
    }

    /// Total bytes of the regular files under a session directory (`output.log`, `service.log`, per-session
    /// sqlite files, plus any sidecars). Uses a shallow-to-deep enumerator so a session dir with subdirs is
    /// still summed correctly; directory entries themselves are skipped so only file payload is counted.
    private static func directorySizeInBytes(_ directory: String, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(atPath: directory) else { return 0 }
        var total: Int64 = 0
        for case let relativePath as String in enumerator {
            let fullPath = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(relativePath).path
            guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath), (attributes[.type] as? FileAttributeType) == .typeRegular
            else { continue }
            total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }

    private static func modificationDate(ofPath path: String, fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
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
