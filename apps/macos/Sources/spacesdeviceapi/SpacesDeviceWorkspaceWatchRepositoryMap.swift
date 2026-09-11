import Foundation
import spacesruntimecore

extension WorkspaceWatch {
    /// One repository in a workspace's watch: the workspace's own repository (`depth == 0`, no
    /// ancestors) or an initialized gitlink checkout beneath it. `gitDir`/`commonDir` are `nil` for a
    /// non-git workspace root (see `discoverRepositoryMap`): there is nothing external to watch and no
    /// ignore set to read, so every other repository-map consumer treats a `nil` pair as "watch the
    /// working directory alone, with no ignore filtering."
    struct RepositoryMapEntry: Sendable {
        let workingDir: String
        let gitDir: String?
        let commonDir: String?
        /// `workingDir` for every ancestor repository, root-to-parent order; empty for the workspace's
        /// own repository.
        let ancestorWorkingDirs: [String]
        let depth: Int
    }

    /// Discovers the workspace's own repository plus every initialized gitlink checkout beneath it, up to
    /// `SpacesDeviceWorkspaceDiffEngine.maxSubmoduleDepth` levels, gated by
    /// `SpacesDeviceWorkspacePathResolver.isContainedGitlinkCheckout`, the same check the diff and
    /// file-list engines use, so all three agree on what counts as a checkout.
    ///
    /// Unlike those engines' own submodule discovery (which reads only the repositories a `git status`
    /// currently reports as dirty), this walks every TRACKED gitlink regardless of its current dirty
    /// state: a currently-clean submodule still needs a watch installed on it now, since a later edit
    /// inside it must be observed without requiring a daemon restart or re-subscription first.
    ///
    /// A workspace root that is not a git repository at all (a plain project directory, the same shape
    /// `SpacesDeviceWorkspaceFileListEngine.listFiles` falls back to `listFilesystemFiles` for) has no
    /// gitlinks to walk and nothing to probe with git, so this returns it as a single ungated entry
    /// instead of running any git command against it. A gitlink checkout below a git root, by contrast,
    /// is always itself a git repository (`isContainedGitlinkCheckout` requires a `.git` entry before
    /// recursion ever reaches it), so only the root needs this check.
    static func discoverRepositoryMap(
        workspaceRoot: String, gitClient: RemoteWorkspaceGitClient, repositoryPathCache: SpacesDeviceWorkspaceFileListEngine.RepositoryPathCache,
        deadlineStart: Date
    ) throws -> [RepositoryMapEntry] {
        guard try gitClient.isRepoStrict(path: workspaceRoot) else {
            return [RepositoryMapEntry(workingDir: workspaceRoot, gitDir: nil, commonDir: nil, ancestorWorkingDirs: [], depth: 0)]
        }
        var entries: [RepositoryMapEntry] = []
        try discoverRepository(
            workingDir: workspaceRoot, ancestorWorkingDirs: [], depth: 0, gitClient: gitClient, repositoryPathCache: repositoryPathCache,
            deadlineStart: deadlineStart, into: &entries)
        return entries
    }

    private static func discoverRepository(
        workingDir: String, ancestorWorkingDirs: [String], depth: Int, gitClient: RemoteWorkspaceGitClient,
        repositoryPathCache: SpacesDeviceWorkspaceFileListEngine.RepositoryPathCache, deadlineStart: Date, into entries: inout [RepositoryMapEntry]
    ) throws {
        let paths = try repositoryPathCache.paths(for: workingDir) {
            try SpacesDeviceWorkspaceFileListEngine.repositoryPaths(workspaceDir: workingDir, gitClient: gitClient, deadlineStart: deadlineStart)
        }
        // git reports `gitDir`/`commonDir` as absolute paths in its own spelling, unresolved (a linked
        // worktree's or a submodule's git dir commonly sits under a symlinked temporary/home directory on
        // macOS), while FSEvents reports the resolved form. Resolved here, at map-entry construction, not
        // by mutating `paths` inside the shared `RepositoryPathCache`: every other cache consumer only
        // fingerprints files through these paths, where spelling is irrelevant, and `WorkspaceWatch`'s own
        // `resolvedWorkspaceRoot` gets the identical treatment for the same reason (see its doc comment).
        entries.append(
            RepositoryMapEntry(
                workingDir: workingDir, gitDir: Self.realPath(paths.gitDir), commonDir: Self.realPath(paths.commonDir),
                ancestorWorkingDirs: ancestorWorkingDirs, depth: depth))
        guard depth < SpacesDeviceWorkspaceDiffEngine.maxSubmoduleDepth else { return }
        // `ls-files -s` (stage) lists every tracked path's mode regardless of working-tree state, unlike
        // `git status`, which only names a gitlink that is CURRENTLY dirty: exactly the gap this walk
        // exists to close (see the type doc).
        let output = try gitClient.runGitAndCapture(["-C", workingDir, "ls-files", "-s", "-z"], timeout: gitCommandTimeout)
        for gitlinkPath in gitlinkPaths(fromLsFilesStageZ: output) {
            guard SpacesDeviceWorkspacePathResolver.isContainedGitlinkCheckout(repoDir: workingDir, repoRelativePath: gitlinkPath) else { continue }
            let subDir = (workingDir as NSString).appendingPathComponent(gitlinkPath)
            try discoverRepository(
                workingDir: subDir, ancestorWorkingDirs: ancestorWorkingDirs + [workingDir], depth: depth + 1, gitClient: gitClient,
                repositoryPathCache: repositoryPathCache, deadlineStart: deadlineStart, into: &entries)
        }
    }

    /// Parses `git ls-files -s -z` records (`<mode> SP <object> SP <stage> TAB <path>`, NUL terminated)
    /// for gitlink entries (mode `160000`), returning their repository-relative paths.
    static func gitlinkPaths(fromLsFilesStageZ output: String) -> [String] {
        output.split(separator: "\u{0}").compactMap { record in
            guard let tabIndex = record.firstIndex(of: "\t") else { return nil }
            let metadata = record[record.startIndex..<tabIndex]
            guard metadata.hasPrefix("160000 ") else { return nil }
            return String(record[record.index(after: tabIndex)...])
        }
    }

    /// Ignored directories for one repository, as absolute paths (each standing for that directory and
    /// everything beneath it). `--directory` is what makes `ls-files` report a whole ignored directory as
    /// one entry rather than descending into it (cheap, and exactly the granularity
    /// `WorkspaceWatchEventAcceptance` checks by prefix), and `--others --ignored --exclude-standard`
    /// matches the membership engine's own ignored-file enumeration.
    /// `limitedTo` narrows the listing to those pathspecs (absolute paths under `workingDir` are accepted
    /// as pathspecs); empty lists the whole repository. `--directory` reports an ignored directory even
    /// while it is still empty, which is what lets a directory created a moment ago be classified.
    static func ignoredDirectories(workingDir: String, gitClient: RemoteWorkspaceGitClient, limitedTo pathspecs: [String] = []) throws -> Set<String>
    {
        let output = try gitClient.runGitAndCapture(
            ["-C", workingDir, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z", "--"] + pathspecs,
            timeout: gitCommandTimeout)
        return Set(
            output.split(separator: "\u{0}").map { entry -> String in
                let relative = entry.hasSuffix("/") ? String(entry.dropLast()) : String(entry)
                return (workingDir as NSString).appendingPathComponent(relative)
            })
    }

    /// The paths to hand `FileSystemWatcher`, per platform.
    ///
    /// Accepted gap: `--exclude-standard` above (and every other ignored-listing call in this file) also
    /// honors an external `core.excludesFile` (the user's global gitignore), but none of these watch sets
    /// add that file's own directory as a watch root, so editing it does not refresh Diff or Files until
    /// the next workspace event happens to occur for some other reason. Accepted because editing the
    /// global excludes file is rare, any subsequent workspace event recomputes with the new rules, and
    /// watching a per-user file outside every workspace root would add a watch root whose events are
    /// almost never relevant to any workspace.
    ///
    /// Accepted gap: for a workspace registered as a SUBDIRECTORY of a larger repository, none of these
    /// watch roots reach above `workspaceRoot`, so a `.gitmodules` or root-level `.gitignore` edit made at
    /// the repository's own root (outside the workspace) is not watched and takes effect only at the next
    /// reinstall (a scope switch, a reload, or a Retry). Accepted because watching the repository root
    /// instead would pull the whole repository into the subtree workspace's watch on macOS (FSEvents
    /// watches recursively, so there is no way to watch just an ancestor's metadata files without covering
    /// everything beneath it too), and editing repository-root metadata while a subtree workspace is open
    /// is rare.
    static func watchPaths(for repositories: [RepositoryMapEntry], workspaceRoot: String, ignoreSets: [String: Set<String>]) -> [String] {
        #if os(macOS)
            return macOSWatchPaths(for: repositories, workspaceRoot: workspaceRoot)
        #elseif os(Linux)
            return linuxWatchPaths(for: repositories, ignoreSets: ignoreSets)
        #endif
    }

    /// FSEvents watches each root recursively, so the workspace root alone covers everything physically
    /// under it; a repository's git dir or common dir can sit outside the workspace root entirely (every
    /// Spaces workspace is a linked worktree, whose git dir lives under the main checkout's common
    /// directory, never inside the worktree it backs, see `RepositoryPaths.gitDir`'s doc comment), so
    /// those are always added too. Adding one that happens to already be nested under another root is
    /// harmless: FSEvents tolerates overlapping recursive roots, it just means that subtree is covered
    /// twice, not incorrectly.
    private static func macOSWatchPaths(for repositories: [RepositoryMapEntry], workspaceRoot: String) -> [String] {
        var paths: Set<String> = [workspaceRoot]
        for repository in repositories {
            if let gitDir = repository.gitDir { paths.insert(gitDir) }
            if let commonDir = repository.commonDir { paths.insert(commonDir) }
        }
        return Array(paths).sorted()
    }

    /// inotify is not recursive, so every directory that can receive a relevant event needs its own watch:
    /// each repository's working tree (walked below, pruning ignored directories so a build output tree
    /// like `node_modules` never grows the watch-descriptor count), its git dir, its common dir, and its
    /// `refs/` tree (walked separately since a new/renamed branch under a nested `refs/heads/...` directory
    /// needs its own watch too, not just the common dir root).
    ///
    /// Simplification versus the plan's exact prescription (deriving the watch set from the file-list
    /// engine's own `ls-files`/`status --untracked-files=all` output): this walks the filesystem directly,
    /// pruning by the same ignore set event acceptance uses. It costs a directory enumeration at install
    /// time instead of reusing an already-computed listing, but keeps this file free of a second
    /// integration with the file-list engine's index-reading internals.
    ///
    /// Each repository's own walk is pruned at every OTHER repository's working directory that sits
    /// beneath it (an initialized submodule checkout): that descendant repository gets its own iteration of
    /// this same loop, with its OWN ignore set, so letting the ANCESTOR's walk descend into it first would
    /// register the descendant's tree under the ancestor's (wrong) ignore rules, e.g. registering
    /// `submodule/node_modules` before the submodule's own `.gitignore` ever gets a chance to exclude it.
    /// Not `private`: exercised directly by `SpacesDeviceWorkspaceWatchTests` as a pure function of the map
    /// plus a filesystem fixture, without needing a real Linux inotify backend.
    static func linuxWatchPaths(for repositories: [RepositoryMapEntry], ignoreSets: [String: Set<String>]) -> [String] {
        var paths: Set<String> = []
        for repository in repositories {
            paths.insert(repository.workingDir)
            let descendantRepositoryRoots = repositories
                .filter { $0.workingDir != repository.workingDir && $0.workingDir.hasPrefix(repository.workingDir + "/") }
                .map(\.workingDir)
            let skip = (ignoreSets[repository.workingDir] ?? []).union(descendantRepositoryRoots)
            enumerateDirectories(under: repository.workingDir, skipping: skip, into: &paths)
            // A non-git repository (nil `gitDir`/`commonDir`) has nothing outside its working directory
            // to watch and no `refs/` tree to walk.
            guard let gitDir = repository.gitDir, let commonDir = repository.commonDir else { continue }
            paths.insert(gitDir)
            paths.insert(commonDir)
            enumerateDirectories(under: (commonDir as NSString).appendingPathComponent("refs"), skipping: [], into: &paths)
            // `<commonDir>/info` (home to `info/exclude`) and, for a repository using the reftable ref
            // storage format (git >= 2.44's `--ref-format=reftable`, which rewrites `reftable/tables.list`
            // on every ref update, see `headFingerprint`), `<commonDir>/reftable` both sit outside `refs/`,
            // so watching `commonDir` alone never covers either one: inotify is not recursive. Checked for
            // existence rather than inserted unconditionally, since neither is guaranteed to exist (most
            // repositories do not use reftable, and a linked worktree's own `gitDir` has no `info` of its
            // own, only the shared `commonDir` does).
            for candidate in [(commonDir as NSString).appendingPathComponent("info"), (commonDir as NSString).appendingPathComponent("reftable")] {
                if FileManager.default.fileExists(atPath: candidate) { paths.insert(candidate) }
            }
            if gitDir != commonDir {
                let gitInfo = (gitDir as NSString).appendingPathComponent("info")
                if FileManager.default.fileExists(atPath: gitInfo) { paths.insert(gitInfo) }
            }
        }
        return Array(paths)
    }

    /// Not `private`: `WorkspaceWatch`'s own file reuses this same walk shape to expand a newly reported
    /// directory (which inotify never separately reports descendants for) into its full, already-on-disk
    /// subtree before registering it.
    static func enumerateDirectories(under root: String, skipping ignored: Set<String>, into paths: inout Set<String>) {
        guard
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        else { return }
        paths.insert(root)
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // A symbolic link is never a directory candidate here, matching `pathIsDirectory`'s `lstat`
            // rule: `.isDirectoryKey` resolves through a symlink (`stat` semantics), so a directory symlink
            // would otherwise be inserted as a watch path and, worse, the enumerator would descend into and
            // register its target's subtree too, which can reach outside the workspace entirely or re-walk
            // an already-registered repository's own tree under a second path. `skipDescendants()` covers
            // the (already unlikely, since `.isDirectoryKey` is false for a symlink) case where the
            // enumerator would otherwise still traverse into the link's target.
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isDirectory == true else { continue }
            // Accepted gap: this `.git` skip is unconditional, so a NESTED repository under a non-git
            // workspace root (one `discoverRepositoryMap` never walked into, since only a git root's own
            // gitlinks are discovered) gets none of its own internals watched, and a change inside that
            // nested repository's `.git` does not refresh the Files list until some other event happens to
            // fire. Accepted because the skip exists to keep a nested repository's objects tree out of the
            // descriptor budget (an ordinary git object store can hold thousands of loose objects, each one
            // a would-be inotify descriptor), and the only paths it hides are git internals, which nobody
            // edits by hand.
            if url.lastPathComponent == ".git" || ignored.contains(url.path) {
                enumerator.skipDescendants()
                continue
            }
            paths.insert(url.path)
        }
    }
}
