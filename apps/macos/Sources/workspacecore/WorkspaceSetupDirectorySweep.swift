import Foundation

/// Removes orphaned `workspace-setup` run directories. `workspaceSetupLogPath` keys one directory per
/// workspace ID under `<runtime>/workspace-setup/` and truncates `setup.log` in place on every run, so
/// a live workspace's directory never grows; nothing, however, removes a directory once its workspace
/// is gone, and they accumulate for as long as the profile exists (issue #423).
///
/// Age is tracked from a sentinel `.orphaned` marker file written the first time a directory is seen
/// without a matching workspace, not from the directory's own modification date: writing/truncating
/// `setup.log` never updates the parent directory's mtime, so a workspace created long before its
/// deletion would otherwise look immediately stale and skip the grace period entirely. The marker's
/// own mtime stands in as the first-seen timestamp; a directory is deleted only once that marker is
/// older than `orphanRetentionInterval`. A directory whose workspace reappears (e.g. discovery
/// re-imports it between daemon startups) has its marker removed, so a later orphaning restarts the
/// clock rather than inheriting the earlier timestamp.
///
/// This is diagnostic-file cleanup only. It never touches the database: a workspace or project record
/// is removed only through the paths the store itself owns (an explicit user delete, or discovery
/// retiring a workspace whose worktree is gone), and this sweep has no access to the store at all —
/// it classifies purely from a set of IDs the caller already resolved.
public enum WorkspaceSetupDirectorySweep {
    /// How long an orphaned directory (no matching workspace in `knownWorkspaceIDs`) survives, counted
    /// from when its `.orphaned` marker was first written, before it is removed. A user who just
    /// deleted a workspace may still be chasing a discovery error that references that workspace's
    /// failed setup log, so cleanup gives it a grace window instead of deleting the log the instant the
    /// workspace record disappears.
    public static let orphanRetentionInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Name of the empty sentinel file written inside a directory the first time it is seen as
    /// orphaned. Its mtime is the first-seen timestamp the retention window is measured from.
    private static let orphanMarkerFileName = ".orphaned"

    /// Classifies every subdirectory of `workspaceSetupDirectory` against `knownWorkspaceIDs`:
    /// - known (live) workspace: any `.orphaned` marker inside is removed (so a later orphaning starts
    ///   a fresh clock); the directory itself is never touched, regardless of marker age.
    /// - orphaned, no marker yet: an empty `.orphaned` marker is created and the directory is left
    ///   alone this run.
    /// - orphaned with a marker older than `orphanRetentionInterval`: the directory is deleted.
    /// - orphaned with a marker still within the window: left alone.
    /// A missing `workspaceSetupDirectory`, or any entry this cannot confidently classify (unreadable
    /// attributes, not a directory), is left alone — this is best-effort disk hygiene, not a
    /// correctness-critical path.
    public static func sweep(workspaceSetupDirectory: String, knownWorkspaceIDs: Set<String>, fileManager: FileManager = .default) {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: workspaceSetupDirectory) else { return }
        for name in entries {
            let entryPath = (workspaceSetupDirectory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entryPath, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let markerPath = (entryPath as NSString).appendingPathComponent(orphanMarkerFileName)

            if knownWorkspaceIDs.contains(name) {
                if fileManager.fileExists(atPath: markerPath) { try? fileManager.removeItem(atPath: markerPath) }
                continue
            }
            guard let markerAttributes = try? fileManager.attributesOfItem(atPath: markerPath),
                let markerModificationDate = markerAttributes[.modificationDate] as? Date
            else {
                _ = fileManager.createFile(atPath: markerPath, contents: nil)
                continue
            }
            guard Date().timeIntervalSince(markerModificationDate) > orphanRetentionInterval else { continue }
            try? fileManager.removeItem(atPath: entryPath)
        }
    }
}
