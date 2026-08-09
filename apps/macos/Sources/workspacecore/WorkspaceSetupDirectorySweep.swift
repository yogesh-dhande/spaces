import Foundation

/// Removes orphaned `workspace-setup` run directories. `workspaceSetupLogPath` keys one directory per
/// workspace ID under `<runtime>/workspace-setup/` and truncates `setup.log` in place on every run, so
/// a live workspace's directory never grows; nothing, however, removes a directory once its workspace
/// is gone, and they accumulate for as long as the profile exists (issue #423).
///
/// This is diagnostic-file cleanup only. It never touches the database: a workspace or project record
/// is removed only through the paths the store itself owns (an explicit user delete, or discovery
/// retiring a workspace whose worktree is gone), and this sweep has no access to the store at all —
/// it classifies purely from a set of IDs the caller already resolved.
public enum WorkspaceSetupDirectorySweep {
    /// How long an orphaned directory (no matching workspace in `knownWorkspaceIDs`) survives before
    /// it is removed. A user who just deleted a workspace may still be chasing a discovery error that
    /// references that workspace's failed setup log, so cleanup gives it a grace window instead of
    /// deleting the log the instant the workspace record disappears.
    public static let orphanRetentionInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Deletes every subdirectory of `workspaceSetupDirectory` whose name is not in
    /// `knownWorkspaceIDs` and whose modification date is older than `orphanRetentionInterval`.
    /// Directories for known (live) workspaces are never touched, regardless of age. A missing
    /// `workspaceSetupDirectory`, or any entry this cannot confidently classify (unreadable
    /// attributes, not a directory), is left alone — this is best-effort disk hygiene, not a
    /// correctness-critical path.
    public static func sweep(
        workspaceSetupDirectory: String, knownWorkspaceIDs: Set<String>, now: Date = Date(), fileManager: FileManager = .default
    ) {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: workspaceSetupDirectory) else { return }
        for name in entries where !knownWorkspaceIDs.contains(name) {
            let entryPath = (workspaceSetupDirectory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entryPath, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard let attributes = try? fileManager.attributesOfItem(atPath: entryPath),
                let modificationDate = attributes[.modificationDate] as? Date
            else { continue }
            guard now.timeIntervalSince(modificationDate) > orphanRetentionInterval else { continue }
            try? fileManager.removeItem(atPath: entryPath)
        }
    }
}
