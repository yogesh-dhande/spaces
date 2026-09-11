import Foundation

/// Pure event-acceptance rules for `WorkspaceWatch` (rules 1-4 in the event-gated refresh plan). Kept
/// free of `WorkspaceWatch`'s own state (the watcher, the debounce timer, the ignore-set cache) so the
/// mapping from one changed path to the repositories it touches is a plain function a test can drive
/// directly, without a filesystem watcher or a real git repository.
enum WorkspaceWatchEventAcceptance {
    /// One repository in a workspace's repository map, as far as event acceptance needs to know it.
    struct Repository: Sendable, Equatable {
        /// Working tree root: the workspace root itself, or a submodule checkout directory.
        let workingDir: String
        /// This repository's own git dir (`.git`, `<common>/worktrees/<name>`, or
        /// `<superproject>/.git/modules/<name>`), which can sit outside `workingDir` entirely. `nil` for a
        /// non-git workspace root, which has no git dir at all.
        let gitDir: String?
        /// Where refs/HEAD/packed-refs actually live; equals `gitDir` unless this is a linked worktree.
        /// `nil` alongside `gitDir` for a non-git workspace root.
        let commonDir: String?
        /// `workingDir` for every ancestor repository, root-to-parent order, empty for the workspace's own
        /// repository. Rule 4 marks all of these touched alongside the repository itself.
        let ancestorWorkingDirs: [String]
    }

    /// git-dir-relative names rule 2 accepts outright; everything else under a git/common dir is dropped
    /// unless it lies under `refs/`. `index`, `packed-refs`, `config`, and `config.worktree` are listed
    /// explicitly: `config`/`config.worktree` because `git config core.fileMode false` (or a submodule's
    /// own ignore setting) rewrites one of these files without touching anything in the working tree, yet
    /// still changes what `git status`/`git diff` report, so a change to either file must be observed the
    /// same as a `HEAD`/`index` change. Every other top-level (no `/`) name is accepted when it is exactly
    /// `HEAD` or matches `<PREFIX>_HEAD` (one or more uppercase letters, digits, or underscores followed by
    /// a literal `_HEAD`), covering `MERGE_HEAD`, `REBASE_HEAD`, `CHERRY_PICK_HEAD`, and `FETCH_HEAD` (`git
    /// fetch <url> <ref>` advances only that one file, no local ref or working-tree change at all) without
    /// enumerating them: the compare field accepts any resolvable ref as a diff scope, including
    /// `ORIG_HEAD` (which `git update-ref ORIG_HEAD <sha>` or an ordinary merge/rebase/reset can rewrite on
    /// its own) and any other custom `<NAME>_HEAD` a hook or script writes, so the rule has to match the
    /// shape rather than a fixed list. The `_HEAD` suffix requirement is what keeps `ORIG_HEAD.lock` (the
    /// lock file git holds while writing the ref) from matching, since it does not itself end in `_HEAD`.
    private static let gitDirAllowedTopLevelNames: Set<String> = ["index", "packed-refs", "config", "config.worktree"]

    /// Whether `name`, already known to be one path component (no `/`) directly under a git or common dir,
    /// is accepted outright by rule 2: see `gitDirAllowedTopLevelNames`'s doc comment for the `HEAD`/
    /// `<PREFIX>_HEAD` shape this also matches.
    private static func isAcceptedGitDirTopLevelName(_ name: String) -> Bool {
        if name == "HEAD" || gitDirAllowedTopLevelNames.contains(name) { return true }
        guard name.hasSuffix("_HEAD") else { return false }
        let prefix = name.dropLast("_HEAD".count)
        return !prefix.isEmpty && prefix.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }
    }

    /// Resolves one changed path to the set of repository working directories it touches (the owning
    /// repository plus every ancestor), or `nil` when rule 2 or rule 3 drops it. `repositories` need not
    /// be sorted; the deepest matching root wins for both the git-dir and the working-dir resolution, so
    /// a nested submodule's own `.git/modules/<name>` is preferred over its superproject's git dir when
    /// both are prefixes.
    ///
    /// `ignoredDirectories` returns one repository's ignored-directory set (absolute paths, each standing
    /// for that directory and everything under it) given its working dir; called only for the repository
    /// rule 4 resolves the path to, matching the plan's "ignored directory" rule being scoped per
    /// repository rather than global.
    static func touchedWorkingDirectories(
        forChangedPath path: String, repositories: [Repository], ignoredDirectories: (_ repositoryWorkingDir: String) -> Set<String>
    ) -> Set<String>? {
        if let repository = deepestGitDirMatch(forChangedPath: path, repositories: repositories) {
            guard nameIsAcceptedUnderGitDir(path: path, repository: repository) else { return nil }
            return Set([repository.workingDir] + repository.ancestorWorkingDirs)
        }
        guard let repository = deepestWorkingDirMatch(forChangedPath: path, repositories: repositories) else { return nil }
        let ignored = ignoredDirectories(repository.workingDir)
        // Accepted gap: a tracked symlink whose target lies inside an ignored directory (e.g. `link ->
        // build/generated.txt`) stays listed in the Files list only while the target is openable and under
        // the membership engine's size cap, and this drop rule fires for a change to that target the same
        // as for any other path under the ignored directory (there is also no inotify watch on an ignored
        // directory on Linux, so the change may not even reach here). The Files list goes stale for that
        // one path until the next accepted event anywhere in the repository recomputes it: self-healing,
        // and rare (it needs a tracked symlink pointed into an ignored directory, plus a change to that
        // exact target). Honoring it would mean watching every ignored directory for symlink targets,
        // which is exactly the descriptor/spawn churn this ignore rule exists to avoid.
        if ignored.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return nil }
        return Set([repository.workingDir] + repository.ancestorWorkingDirs)
    }

    /// The repository whose git dir or common dir is the deepest (longest) prefix of `path`, if any. A
    /// worktree's git dir and a submodule's `.git/modules/<name>` directory both commonly sit outside
    /// every working dir, so this is checked independently of `deepestWorkingDirMatch`. A non-git
    /// repository's `nil` roots are dropped by the `compactMap` rather than compared: an empty-string
    /// sentinel would match every absolute path via the `+ "/"` prefix check below.
    private static func deepestGitDirMatch(forChangedPath path: String, repositories: [Repository]) -> Repository? {
        var best: (repository: Repository, rootLength: Int)?
        for repository in repositories {
            for root in [repository.gitDir, repository.commonDir].compactMap({ $0 }) {
                guard path == root || path.hasPrefix(root + "/") else { continue }
                if best == nil || root.count > best!.rootLength { best = (repository, root.count) }
            }
        }
        return best?.repository
    }

    /// Whether `path`, already known to sit under `repository`'s git dir or common dir, names one of the
    /// files rule 2 whitelists, lies under `refs/` or `reftable/`, or is the repo-level exclude file.
    /// Checked against both roots (a linked worktree's `HEAD` lives under `gitDir`; `refs/`, `reftable/`,
    /// and `info/exclude` live under `commonDir`), since either can be the root that actually matched.
    /// `reftable/` covers a repository using the reftable ref storage format (git >= 2.44), which rewrites
    /// `reftable/tables.list` on every ref update instead of touching anything under `refs/`.
    private static func nameIsAcceptedUnderGitDir(path: String, repository: Repository) -> Bool {
        for root in [repository.gitDir, repository.commonDir].compactMap({ $0 }) {
            guard path == root || path.hasPrefix(root + "/") else { continue }
            let relative = String(path.dropFirst(root.count + 1))
            if isAcceptedGitDirTopLevelName(relative) || relative.hasPrefix("refs/") || relative.hasPrefix("reftable/")
                || relative == "info/exclude"
            {
                return true
            }
        }
        return false
    }

    /// The repository whose working directory is the deepest (longest) prefix of `path`. Not `private`:
    /// `WorkspaceWatch` reuses this exact rule (rather than a separate `first(where:)` loop) for its own
    /// pre-acceptance repository lookups (`isUnclassifiedNewDirectory`, `classifyNewDirectories`), since a
    /// shallower match there would classify a directory created inside a submodule against the
    /// superproject's ignore rules instead of the submodule's own.
    static func deepestWorkingDirMatch(forChangedPath path: String, repositories: [Repository]) -> Repository? {
        var best: (repository: Repository, rootLength: Int)?
        for repository in repositories {
            let root = repository.workingDir
            guard path == root || path.hasPrefix(root + "/") else { continue }
            if best == nil || root.count > best!.rootLength { best = (repository, root.count) }
        }
        return best?.repository
    }
}
