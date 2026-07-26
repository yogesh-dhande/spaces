import Foundation

/// Reclaims on-disk terminal state the row-driven garbage collector can never see.
///
/// `TerminalSessionGarbageCollector` discovers sessions from DB rows only (`listKnownSessions`), so a
/// directory under the sessions root that has *no* `terminal_sessions` row is invisible to it and would
/// accumulate forever. Two kinds of such garbage exist:
///  1. Orphaned session directories: a session dir whose ID has no row — a core that crashed after
///     `ensureDirectories` but before committing its launch-configuration row, or a leftover from a
///     historical partial delete. The row-driven collector never iterates it, so nothing else reclaims it.
///  2. Stale trim temp files: `TerminalTranscriptTrim` writes `<dir>/output.log.trim` and then atomically
///     renames it over `output.log`. A crash between the write and the rename leaves the `.trim` sibling
///     behind. The trimmer overwrites any leftover on its *next* trim, so this only strands sessions that
///     never trim again (short-lived, or ended before growing back to the trim threshold).
///
/// This sweep runs on the same daemon GC cadence and is the single door that reclaims both. It is
/// deliberately conservative: it deletes only what it can prove is abandoned.
public enum TerminalSessionOrphanSweep {
    /// Sweeps the sessions root once, removing abandoned session directories and stale trim temp files.
    /// Returns the paths removed. `knownSessionIDs` are the IDs the caller found in the DB;
    /// `activeSessionIDs` are the sessions the daemon still owns in memory (live cores).
    ///
    /// Two independent guards keep this from deleting live state:
    ///  - **Grace period.** A dir is a deletion candidate only when its own modification time is older than
    ///    `now - gracePeriod` (default one hour at the call site). A session dir is created (mtime set)
    ///    before its row is committed, and a trim's `.trim` file exists for only the milliseconds between
    ///    write and rename — so any entry younger than the grace period may be a creation or a trim racing
    ///    this very sweep, and is left alone. An entry older than the grace period cannot be either: a
    ///    mid-creation core would have committed its row (making it "known") long ago, and an in-flight
    ///    trim completes in milliseconds. The grace period is what makes "no row" safely mean "abandoned"
    ///    rather than "not yet committed".
    ///  - **Known ∪ active set.** A dir whose name is in *either* set is never deleted, regardless of age.
    ///    `knownSessionIDs` covers sessions with a committed row; `activeSessionIDs` covers live in-memory
    ///    cores that may not have committed their row yet. Both are required: a live core's row can lag its
    ///    directory, so guarding on the DB set alone would let the sweep delete the working directory of a
    ///    running session out from under it. A dir in either set is a real session, not garbage; for those
    ///    the sweep reclaims only a stale `.trim` sibling, never the dir itself.
    ///
    /// Failures are contained the same way the collector contains a per-session purge failure: a single
    /// entry that cannot be read or removed is reported through `onFailure(path:error:)` and the sweep
    /// continues, so one undeletable entry never blocks reclaiming the rest on this or any later sweep.
    /// Attribute reads fail *closed*: an entry whose type or modification date cannot be read is skipped,
    /// never deleted, because we would rather leak an unreadable entry than delete something we cannot
    /// prove is an abandoned directory. Non-directory strays at the root (files this sweep does not own)
    /// are likewise left untouched. Only a failure to *list* the root throws, since with no listing there
    /// is nothing to iterate.
    @discardableResult
    public static func sweep(
        knownSessionIDs: Set<String>,
        activeSessionIDs: Set<String>,
        gracePeriod: TimeInterval,
        fileManager: FileManager = .default,
        now: Date = Date(),
        onFailure: (String, any Error) -> Void = { _, _ in }
    ) throws -> [String] {
        let rootPath = try TerminalSessionPaths.sessionsRootDirectory(fileManager: fileManager)
        let entries = try fileManager.contentsOfDirectory(atPath: rootPath)

        let cutoff = now.addingTimeInterval(-gracePeriod)
        let guardedIDs = knownSessionIDs.union(activeSessionIDs)
        var removed: [String] = []

        for entry in entries {
            let entryPath = URL(fileURLWithPath: rootPath).appendingPathComponent(entry).path

            // Fail closed: an entry whose attributes are unreadable is neither provably a directory nor
            // provably old, so leave it rather than risk deleting live or foreign state.
            guard let attributes = try? fileManager.attributesOfItem(atPath: entryPath) else { continue }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }

            if guardedIDs.contains(entry) {
                // A real session directory: never deleted here. Reclaim only a crash-stranded trim temp.
                removeStaleTrimFile(inSessionDirectory: entryPath, cutoff: cutoff, fileManager: fileManager, onFailure: onFailure)
                    .map { removed.append($0) }
                continue
            }

            // An orphaned directory: no row, no live core. Delete only once it is past the grace period.
            guard let modificationDate = attributes[.modificationDate] as? Date, modificationDate < cutoff else { continue }
            do {
                try fileManager.removeItem(atPath: entryPath)
                removed.append(entryPath)
            } catch {
                onFailure(entryPath, error)
            }
        }

        return removed
    }

    /// Removes `<sessionDirectory>/output.log.trim` when it is a crash leftover — present and older than
    /// `cutoff`. Returns the removed path, or `nil` when there is nothing to reclaim (no temp file, an
    /// in-flight one still inside the grace period, or an unreadable/undeletable one, both of which fail
    /// closed and are reported through `onFailure`).
    private static func removeStaleTrimFile(
        inSessionDirectory sessionDirectory: String, cutoff: Date, fileManager: FileManager, onFailure: (String, any Error) -> Void
    ) -> String? {
        let trimPath = URL(fileURLWithPath: sessionDirectory).appendingPathComponent("output.log.trim").path
        // A missing temp file simply throws here; that is the common case and is silently skipped.
        guard let attributes = try? fileManager.attributesOfItem(atPath: trimPath) else { return nil }
        guard let modificationDate = attributes[.modificationDate] as? Date, modificationDate < cutoff else { return nil }
        do {
            try fileManager.removeItem(atPath: trimPath)
            return trimPath
        } catch {
            onFailure(trimPath, error)
            return nil
        }
    }
}
