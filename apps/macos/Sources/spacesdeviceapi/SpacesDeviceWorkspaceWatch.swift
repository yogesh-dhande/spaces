import Foundation
import spacesruntimecore
import workspacecore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// One filesystem watch shared by every live diff/file-list subscription for a workspace. Owns the
/// underlying `FileSystemWatcher`, the workspace's repository map (its own repository plus every
/// initialized gitlink checkout beneath it), each repository's ignore set, and the debounce that turns a
/// burst of filesystem events into one "these repositories changed" firing handed to every subscriber.
///
/// Reference-counted by its subscribers, the same pattern `WorkspaceDiffSignatureSubscription.subscriberCount`
/// uses: `SpacesDeviceAPIServer` owns one `WorkspaceWatch` per workspace id, shared by that workspace's
/// diff-signature and file-list-signature subscriptions, so a workspace with both panes open pays for one
/// `FileSystemWatcher`, not two.
///
/// All mutable state (the watcher, the repository map, ignore sets, the debounce timer, and the touched
/// accumulator) is confined to `queue`, including every call from a subscriber (`subscribe`/`unsubscribe`):
/// those run `queue.sync`, which is safe here because nothing on `queue` ever calls back into a
/// subscriber synchronously (firings are dispatched, not called inline).
final class WorkspaceWatch: @unchecked Sendable {
    /// Which repositories (by working directory) a firing says changed, or `all` when the touched set
    /// itself is not trustworthy (an overflow/rescan event) and every repository must be treated as
    /// touched. Handed to a producer's recompute, which converts it into `RepositoryTouchedSet`.
    struct Touched: Sendable {
        let all: Bool
        let directories: Set<String>
        static let none = Touched(all: false, directories: [])
    }

    typealias WatcherFactory =
        @Sendable (_ paths: [String], _ onChange: @escaping @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void) -> any FileSystemWatching

    /// Bounds every git subprocess the install path spawns (repository-map discovery, ignore-set reads).
    /// Matches the flat, no-request-budget timeout the rest of this file's sibling engines use for a
    /// one-off probe outside any single request's deadline. Not `private`: shared with the repository-map
    /// and Linux-`addPaths` extensions in their own files.
    static let gitCommandTimeout: TimeInterval = 30

    private static let liveWatcherFactory: WatcherFactory = { paths, onChange in FileSystemWatcher(paths: paths, latency: 0, onChange: onChange) }

    private let workspaceRoot: String
    /// `workspaceRoot` with every symlink component resolved, computed once at init. FSEvents and git both
    /// report realpaths (macOS's own default temporary directory, `/var/folders/...`, is itself a symlink
    /// to `/private/var/folders/...`, so this is not a rare case), while `workspaceRoot` is whatever the
    /// caller recorded, symlink or not. Every internal lookup (repository-map discovery, watch paths,
    /// ignore sets, event acceptance) runs in this resolved form so it matches what the OS actually reports;
    /// `unresolveTouchedDirectory(_:)` rewrites the resolved form back to `workspaceRoot` before a touched
    /// set reaches a handler, since producers key their caches by the given, unresolved `workspace.dir`.
    /// Each repository's `gitDir`/`commonDir` in the map get this same `realPath` treatment at discovery
    /// time (`SpacesDeviceWorkspaceWatchRepositoryMap.swift`'s `discoverRepository`), since git prints
    /// those absolute paths in its own spelling too, and event acceptance needs every root compared against
    /// FSEvents/inotify's reported paths on the same footing as `resolvedWorkspaceRoot`.
    private let resolvedWorkspaceRoot: String
    private let gitClient: RemoteWorkspaceGitClient
    private let makeWatcher: WatcherFactory
    private let debounceInterval: TimeInterval
    private let debounceCeiling: TimeInterval
    private let queue = DispatchQueue(label: "spaces.workspace-watch")

    private var watcher: (any FileSystemWatching)?
    private var repositories: [RepositoryMapEntry] = []
    private var ignoreSets: [String: Set<String>] = [:]
    /// Non-ignored directories `classifyNewDirectories` has already classified, keyed by repository
    /// working directory: FSEvents (and, on Linux, a `mkdir`-then-write sequence) reports a directory's
    /// path again on every later create/rename INSIDE it, since an atomic save writes a temp file and
    /// renames it into place, both attributed to the containing directory, so without this an ordinary
    /// edit loop under an already-classified directory would rerun `git ls-files` on it forever.
    /// `isUnclassifiedNewDirectory` treats membership here as "already classified, skip"; reset for one
    /// repository whenever `refreshIgnoreSetIfGitignoreChanged` refreshes its ignore set (the old
    /// classification was made under rules that no longer hold) and for every repository on a full
    /// reinstall (`attemptInstallLocked` starts every repository's classification state over from nothing).
    private var classifiedDirectories: [String: Set<String>] = [:]
    private var lastStartErrorText: String?
    private var subscriberCount = 0
    private var handlers: [UUID: @Sendable (Touched) -> Void] = [:]

    private var pendingTouched = Touched.none
    private var debounceTimer: DispatchSourceTimer?
    private var burstStartedAt: Date?

    init(
        workspaceRoot: String, gitClient: RemoteWorkspaceGitClient, debounceInterval: TimeInterval = 0.5, debounceCeiling: TimeInterval = 2,
        watcherFactory: @escaping WatcherFactory = WorkspaceWatch.liveWatcherFactory
    ) {
        self.workspaceRoot = workspaceRoot
        self.resolvedWorkspaceRoot = Self.realPath(workspaceRoot)
        self.gitClient = gitClient
        self.debounceInterval = debounceInterval
        self.debounceCeiling = debounceCeiling
        self.makeWatcher = watcherFactory
    }

    /// Registers `handler` to receive this workspace's touched-repository sets as events fire, and
    /// retries the underlying install first if the watch is not currently healthy, whether it was never
    /// started, a previous attempt failed outright, or it is running with a recorded error from a PARTIAL
    /// failure (e.g. a Linux `addPaths` call that could not register a newly created directory: the
    /// watcher itself keeps running, only that one directory's coverage is missing). There is no way to
    /// patch just the missing piece from here, so a recorded error forces the same full reinstall a nil
    /// watcher does, discarding the old watcher first. Returns the subscription token (for `unsubscribe`)
    /// and the install error text if the (retried) install fails; `nil` when the watch is healthy. A
    /// caller whose own subscription independently computes an initial signature does so either way; this
    /// only reports whether FUTURE recomputes will be event-driven for this particular new subscription's
    /// frames: an already-established sibling subscription is unaffected until its own re-subscribe.
    func subscribe(_ handler: @escaping @Sendable (Touched) -> Void) -> (token: UUID, startError: String?) {
        queue.sync {
            subscriberCount += 1
            if watcher == nil {
                attemptInstallLocked()
            } else if lastStartErrorText != nil {
                watcher?.stop()
                watcher = nil
                attemptInstallLocked()
            }
            let token = UUID()
            handlers[token] = handler
            return (token, lastStartErrorText)
        }
    }

    /// Releases one subscriber, tearing the watcher and every cached repository/ignore-set/classification
    /// fact down once none remain: the next `subscribe` after that starts a fresh install from scratch
    /// (`watcher == nil` forces `attemptInstallLocked` the same way a brand-new instance's first subscribe
    /// does). This instance itself is not discarded: `SpacesDeviceAPIServer.acquireWorkspaceWatch` keeps it
    /// in its shared-watch map for the daemon's life once any stream has subscribed to this workspace, so
    /// an idle watch between subscribers is this teardown's steady state, not a transient one.
    func unsubscribe(_ token: UUID) {
        queue.sync {
            handlers.removeValue(forKey: token)
            subscriberCount = max(0, subscriberCount - 1)
            guard subscriberCount == 0 else { return }
            watcher?.stop()
            watcher = nil
            debounceTimer?.cancel()
            debounceTimer = nil
            pendingTouched = .none
            burstStartedAt = nil
            repositories = []
            ignoreSets = [:]
            classifiedDirectories = [:]
            lastStartErrorText = nil
        }
    }

    /// Runs the whole install pipeline: discover the repository map, read each repository's ignore set,
    /// build the platform watch-path list, and start the underlying `FileSystemWatcher`. On any failure
    /// (a git spawn, or the watcher's own `start()`) leaves `watcher` nil (so the next `subscribe` retries)
    /// and records the failure's text. Must run on `queue`.
    private func attemptInstallLocked() {
        // Captured before the attempt mutates `lastStartErrorText`: this is a RECOVERY (some earlier
        // subscriber, or an earlier attempt of this same subscriber, left the watch in a failed state) if
        // and only if an error was already recorded coming in.
        let wasRecovering = lastStartErrorText != nil
        do {
            let repositoryPathCache = SpacesDeviceWorkspaceFileListEngine.RepositoryPathCache()
            // This map is a snapshot, rebuilt on every install: `handleFileSystemEvent`'s
            // `isRepositoryMapInvalidatingPath` check reinstalls (via this same method) whenever
            // `.gitmodules` or a repository's `config` changes, so a submodule added or initialized while
            // a subscription is live still ends up in `discovered` as its own repository, not left
            // attributed to whichever ancestor's working directory happened to contain it.
            let discovered = try Self.discoverRepositoryMap(
                workspaceRoot: resolvedWorkspaceRoot, gitClient: gitClient, repositoryPathCache: repositoryPathCache, deadlineStart: Date())
            var ignore: [String: Set<String>] = [:]
            for repository in discovered {
                // A non-git repository (nil `gitDir`) has no ignore set to read: every event under it is
                // touched, matching `WorkspaceWatchEventAcceptance`'s "no ignore filtering" rule for one.
                ignore[repository.workingDir] =
                    repository.gitDir == nil ? [] : try Self.ignoredDirectories(workingDir: repository.workingDir, gitClient: gitClient)
            }
            // Accepted gap (Linux): `watchPaths` (and `linuxWatchPaths`'s own directory walk inside it) is a
            // one-time enumeration of what exists right now. A non-ignored directory created after this
            // enumeration but before `newWatcher.start()` below has actually registered its parent's
            // descriptor gets no descriptor of its own and no IN_CREATE for anything under it, since inotify
            // never retroactively covers a directory that already existed by the time a watch was placed on
            // its parent. In practice this window is the enumeration plus registration time on an ordinary
            // repository, sub-second, and needs a directory creation landing inside that exact window to
            // matter; it heals on the next reinstall (a scope switch, a reload, or a Retry), the same way
            // the submodule gap above does. A fix would mean re-enumerating (or diffing) after `start()`
            // succeeds on every install, doubling that cost for every subscription just to close a
            // sub-second, self-healing window.
            let watchPaths = Self.watchPaths(for: discovered, workspaceRoot: resolvedWorkspaceRoot, ignoreSets: ignore)
            let newWatcher = makeWatcher(watchPaths) { [weak self] paths, mustRescan in
                // Bind a strong `self` here rather than reading the outer weak `self` var a second time
                // inside the nested `queue.async` block: the Linux toolchain rejects that as a reference
                // to a captured var in concurrently-executing code.
                guard let self else { return }
                self.queue.async { self.handleFileSystemEvent(paths: paths, mustRescan: mustRescan) }
            }
            try Self.runBlocking { try await newWatcher.start() }
            repositories = discovered
            ignoreSets = ignore
            // A full reinstall starts classification over from nothing: the new repository map and ignore
            // sets can disagree with whatever `classifiedDirectories` remembered from before (a repository
            // can even be a different one now, after a scope switch), so a stale "already classified" entry
            // must never survive an install it was not computed against.
            classifiedDirectories = [:]
            watcher = newWatcher
            lastStartErrorText = nil
            // This install is a recovery from a previously recorded failure: some subscriber saw
            // `currentStartError()` return non-nil (and may still be showing a stale error banner), and
            // every OTHER live subscription's own handler still has its last-known-bad signature cached, so
            // it will keep re-broadcasting the old error on its own keepalive cadence until it recomputes.
            // Force that recompute for every handler (not just the one that triggered this reinstall) by
            // routing a full touch through the normal debounce path. Handlers must never be called
            // synchronously here: this runs inside `subscribe`'s `queue.sync`, and `handleTouched` on the
            // caller side can itself call back into this watch (e.g. `currentStartError()`), which would
            // reenter the confining queue.
            if wasRecovering {
                pendingTouched = Touched(all: true, directories: [])
                armDebounce()
            }
        } catch {
            watcher = nil
            lastStartErrorText = Self.annotatedErrorText(for: "\(error)")
        }
    }

    /// The install/health error text a subscriber last saw, or the current one when a later failure (e.g.
    /// a Linux `addPaths` call after a healthy install) has since replaced it. `subscribe()` only returns
    /// this at install time; a producer re-reads it on every touched-driven recompute (see
    /// `SpacesDeviceAPIServer`'s `handleTouched`) so a failure that surfaces after the initial install
    /// still reaches the next frame, and a later recovery clears it back to `nil`.
    func currentStartError() -> String? {
        queue.sync { lastStartErrorText }
    }

    /// `WatchError`'s own text names the syscall and the OS's `strerror`, but not the fix: raising the
    /// `fs.inotify.max_user_watches` sysctl is the only way to recover from an `ENOSPC` inotify failure, so
    /// this appends the concrete remediation whenever that code appears in the text, leaving every other
    /// error unchanged.
    static func annotatedErrorText(for text: String) -> String {
        guard text.contains("ENOSPC") else { return text }
        return text + " Raise fs.inotify.max_user_watches on the device."
    }

    /// Bridges `FileSystemWatcher.start()`'s async setup (which suspends across FSEvents/inotify IPC that
    /// can stall for seconds under load) into this type's synchronous install path. Blocking `queue` here
    /// is the same tradeoff the rest of this git-engine-style code already makes: a slow/wedged workspace
    /// degrades only its own dedicated queue, never a shared one: `subscribe`/`unsubscribe` run on
    /// `queue.sync` from a caller's own per-scope `streamQueue`, never from the server's shared state queue.
    private static func runBlocking(_ body: @escaping @Sendable () async throws -> Void) throws {
        final class ErrorBox: @unchecked Sendable { var error: (any Error)? }
        let box = ErrorBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do { try await body() } catch { box.error = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error { throw error }
    }

    /// Runs on `queue` (dispatched there by the watcher's own onChange closure). On Linux, first registers
    /// any newly created directory under a repository's `refs/` tree directly (no classification: a
    /// git-dir path is never gitignored). Classifies any newly created WORKING-tree directory against its
    /// repository's ignore rules next, then resolves each reported path against the event-acceptance rules
    /// (refreshing an affected repository's ignore set first when the path names its
    /// `.gitignore`/`.git/info/exclude`), then arms or extends the debounce once at least one path was
    /// accepted (or the backend reported a rescan).
    ///
    /// Classification must precede acceptance, not follow it: a directory born after install (a build
    /// output tree a `.gitignore` rule covers, say) has no entry in the install time `ignoreSets`
    /// snapshot, on either platform, until something classifies it. If acceptance ran first, that
    /// directory's own creation event, and the file-write events that follow inside it, would be judged
    /// against the stale ignore set and accepted, which is exactly the gap this ordering closes: by the
    /// time the acceptance pass below reads `ignoreSets`, a freshly ignored directory is already in it.
    private func handleFileSystemEvent(paths: [String], mustRescan: Bool) {
        guard !mustRescan else {
            // A rescan (Linux `IN_Q_OVERFLOW`, an FSEvents history-dropped flag) means the backend lost
            // events rather than merely coalescing them, so the lost batch could have included a directory
            // or submodule creation the watch set never registered a descriptor for; on Linux in
            // particular, that leaves the running watcher with a gap `addPaths` never gets a chance to
            // close. Routing this through the same reinstall the map invalidators below use closes that
            // gap by rebuilding the map and watch set from scratch. Rare (a rescan needs sustained event
            // pressure past the backend's own queue depth), and its cost is bounded by the very install
            // path every subscription already pays once.
            watcher?.stop()
            watcher = nil
            attemptInstallLocked()
            pendingTouched = Touched(all: true, directories: [])
            armDebounce()
            return
        }
        #if os(Linux)
            // A directory newly created under any repository's `refs/` tree (a slash-containing branch
            // name, e.g. `refs/heads/feature/`, or a fetch populating `refs/remotes/origin/...`) needs its
            // own inotify watch the same way any other new directory does, but `isUnclassifiedNewDirectory`
            // below never matches it: that check only ever resolves a repository's WORKING directory, never
            // its git or common dir. git-dir paths are never gitignored, so this skips classification
            // entirely and registers the new ref directory (and its already-on-disk descendants) directly.
            let newRefDirectoryCandidates = paths.filter(isNewDirectoryUnderRefs)
            if !newRefDirectoryCandidates.isEmpty { registerWithWatcher(expandedWithDescendants(newRefDirectoryCandidates, skipping: [])) }
            // A directory already classified as not ignored, reported again (a branch switch that deletes
            // and recreates it, or a prepared subtree moved back into place, say): forget that
            // classification for the path and everything already classified beneath it, so the
            // unclassified-new-directory path just below (`isUnclassifiedNewDirectory` ->
            // `classifyNewDirectories`) picks it up again in this SAME event batch. That path walks the
            // directory fresh, classifies every descendant prefix-aware, and registers each non-ignored one
            // with the watcher, which is what a directory reappearing at this path needs even when the
            // recreate populated a NESTED subtree underneath it: re-registering just the top path alone (an
            // earlier version of this did that) restored only the top descriptor, leaving any populated
            // nested directory unwatched. Linux-only: on macOS FSEvents reports the parent directory again
            // on every child save regardless of classification memory, so nothing here ever goes stale on
            // that platform; on Linux, inotify names a directory only on its own create, move, delete, or
            // attribute change, so a classified directory being reported again is rare, and paying for a
            // fresh reclassification (`classifyNewDirectories`'s own cost) each time it happens is cheap.
            for path in paths { forgetStaleClassificationIfRecreated(path) }
        #endif
        // Set by either `refreshIgnoreSetIfGitignoreChanged` (Linux, a `config`/`.gitignore` edit that
        // actually changed the ignore set), the `isRepositoryMapInvalidatingPath` check below
        // (`.gitmodules`/`config` adding or initializing a submodule), or `classifyNewDirectories`'s own
        // return value just below (Linux: a newly registered directory already holds a `.git` entry, e.g.
        // a submodule checkout `git submodule update --init` materialized into a directory that did not
        // exist yet, whose gitfile lands before that directory's own watch does and so is never separately
        // delivered), one flag shared by all three so a single event batch that trips more than one of them
        // at once still reinstalls only once.
        var needsMapRebuild = false
        let newDirectoryCandidates = paths.filter(isUnclassifiedNewDirectory)
        if !newDirectoryCandidates.isEmpty, classifyNewDirectories(newDirectoryCandidates) { needsMapRebuild = true }

        var accepted = false
        for path in paths {
            refreshIgnoreSetIfGitignoreChanged(forChangedPath: path, needsMapRebuild: &needsMapRebuild)
            // Checked before acceptance, not after: a path naming a repository's git dir or common dir
            // ROOT itself (the directory deleted or renamed) derives an empty relative name in
            // `nameIsAcceptedUnderGitDir` and so is rejected as an ordinary event below, but it must still
            // trigger a map rebuild, which the `guard accepted || needsMapRebuild` line further down keeps
            // possible even when every path in this batch is one of these otherwise-rejected events.
            if isRepositoryMapInvalidatingPath(path) { needsMapRebuild = true }
            guard
                let touchedDirs = WorkspaceWatchEventAcceptance.touchedWorkingDirectories(
                    forChangedPath: path, repositories: eventAcceptanceRepositories(), ignoredDirectories: { self.ignoreSets[$0] ?? [] })
            else { continue }
            accepted = true
            pendingTouched = Touched(all: pendingTouched.all, directories: pendingTouched.directories.union(touchedDirs))
        }
        guard accepted || needsMapRebuild else { return }
        if needsMapRebuild {
            // `.gitmodules` and a repository's `config` change rarely (a `git submodule add`/`update
            // --init`, run by hand or by a terminal command inside the workspace), so paying for a full
            // reinstall on every such write is cheap next to the alternative: without it, a submodule
            // added or initialized while a subscription is live is invisible to the repository map until
            // some unrelated event happens to trigger the next reinstall, so its edits keep landing on the
            // superproject's already-cached contribution instead of building one of their own, leaving
            // Diff/Files for it frozen indefinitely rather than briefly.
            watcher?.stop()
            watcher = nil
            attemptInstallLocked()
            // The touched set collected above was computed against the now-stale map, and a newly mapped
            // repository has no cached contribution yet, so the recompute this triggers must rebuild
            // everything rather than trust that union.
            pendingTouched = Touched(all: true, directories: [])
        }
        armDebounce()
    }

    /// Whether `path` is a file whose change can add or remove a repository from the workspace's
    /// repository map: `.gitmodules` directly under a repository's working directory (`git submodule add`
    /// rewrites it, alongside the index) or `config` directly under a repository's git or common dir
    /// (`git submodule update --init` for an already-recorded entry writes `submodule.<name>.url` into
    /// `config`, without touching `.gitmodules` at all). Checked against the CURRENT map, which is exactly
    /// right for `git submodule add` (the superproject the write lands in is already mapped) and for `git
    /// submodule update --init` (the entry being initialized is a `.gitmodules` record under an
    /// already-mapped superproject, not a new repository itself, so its own `workingDir` is not tested
    /// here). Both file names are already accepted by ordinary event acceptance (`.gitmodules` as a plain
    /// tracked file, `config` via `WorkspaceWatchEventAcceptance`'s git-dir allowlist), so this only adds
    /// the map-rebuild reaction on top of the touched-set contribution acceptance already recorded.
    ///
    /// `path == gitDir || path == commonDir` also counts: a repository's `.git` directory itself being
    /// deleted or renamed (dropping out of git entirely, or into a different one) needs the same rebuild,
    /// but a path naming the git dir ROOT itself derives an empty relative name in
    /// `WorkspaceWatchEventAcceptance.nameIsAcceptedUnderGitDir`, which rejects it as an ordinary event
    /// (this predicate runs on every path, not just accepted ones, so that rejection does not gate it). No
    /// change is needed on the acceptance side: the reinstall this triggers already forces an all-touched
    /// firing below, so the rejected event's own touched-set contribution is moot.
    ///
    /// A `.git` (file or directory) anywhere under a mapped repository's WORKING directory, at ANY depth,
    /// also counts, not just directly under it: `git submodule update --init` on an already-tracked
    /// gitlink writes the superproject's `config` (the `submodule.<name>.url` entry) BEFORE the
    /// submodule's checkout directory, or its own `.git`, even exist, so the rebuild that `config` write
    /// triggers still finds an uninitialized checkout; the checkout only actually becomes a repository
    /// once its OWN `<workingDir>/<gitlink>/.git` is created moments later, and that path is never a
    /// direct child of any repository already in the map (it sits one level below the superproject's
    /// working directory), so a check scoped to `<workingDir>/.git` alone misses it. A `.git` entry only
    /// ever appears when a repository is initialized or materialized (`git init`, `submodule update
    /// --init`, `worktree add`), so this only costs a rebuild on those rare events, never on an ordinary
    /// file that happens to sit near one. Checked against every repository's WORKING directory rather than
    /// its (possibly nil) `gitDir`/`commonDir`: a non-git repository entry has neither, so a subscribed
    /// non-git workspace running `git init` would otherwise never be noticed. This also already covers the
    /// case where `.git` sits directly under `workingDir` (an ordinary repository's own `.git`, or a
    /// linked worktree's `.git` indirection file, rewritten or deleted by `git worktree move`/`remove` on
    /// the main checkout, or by hand); no separate check for that shallower case is needed.
    ///
    /// Accepted gap: this `.gitmodules` check (and `refreshIgnoreSetIfGitignoreChanged`'s own `.gitignore`
    /// check elsewhere) is scoped to a repository's `workingDir`, which is the WORKSPACE root for a
    /// workspace registered as a subdirectory of a larger repository, not that repository's own root. A
    /// `.gitmodules` or root-level `.gitignore` edit made above the workspace root is invisible here and
    /// takes effect only at the next reinstall (a scope switch, a reload, or a Retry), not live. Accepted
    /// because watching the repository root instead would pull the whole repository into the subtree
    /// workspace's watch on macOS (FSEvents watches recursively, so there is no way to watch just one
    /// ancestor's metadata files without covering everything beneath it too), and editing repository-root
    /// metadata while a subtree workspace is open is rare.
    ///
    /// Accepted: a branch switch that adds or removes a gitlink in the index while `.gitmodules` stays
    /// byte-identical does not rebuild the map, since the index itself is deliberately not an invalidator
    /// (every `git add`, commit, and checkout writes it, and a reinstall costs a repository discovery plus
    /// one `ls-files` listing per repository). The nested checkout's events then attribute to its parent
    /// and its cached contribution goes stale until the next reinstall (Retry, a `.gitmodules`/`config`
    /// write, a `.git` entry event, or a resubscribe). `git submodule add` and `git rm` both rewrite
    /// `.gitmodules`, so a membership change with an unchanged `.gitmodules` needs a hand-built history and
    /// is not worth a gitlink listing on every index write.
    private func isRepositoryMapInvalidatingPath(_ path: String) -> Bool {
        for repository in repositories {
            if path == (repository.workingDir as NSString).appendingPathComponent(".gitmodules") { return true }
            if path.hasPrefix(repository.workingDir + "/") && (path as NSString).lastPathComponent == ".git" { return true }
            for root in [repository.gitDir, repository.commonDir].compactMap({ $0 }) {
                if path == (root as NSString).appendingPathComponent("config") || path == root { return true }
            }
        }
        return false
    }

    /// Whether `path` is a directory that has not already been classified: not yet reflected in its
    /// repository's ignore set (whichever way that answer eventually falls) and not a repository root
    /// itself, which is never ignored and never needs an ignore-listing spawn to establish that. Repository
    /// membership is resolved by the DEEPEST (longest) working-dir match, via
    /// `WorkspaceWatchEventAcceptance.deepestWorkingDirMatch`, the same rule `classifyNewDirectories`'s own
    /// grouping uses and event acceptance itself uses: a shallower match would attribute a directory
    /// created inside a submodule to the superproject instead, whose `ls-files` never lists a path under a
    /// gitlink, so it would never land in the submodule's own ignore set.
    private func isUnclassifiedNewDirectory(_ path: String) -> Bool {
        guard Self.pathIsDirectory(path) else { return false }
        guard
            let repository = WorkspaceWatchEventAcceptance.deepestWorkingDirMatch(forChangedPath: path, repositories: eventAcceptanceRepositories()),
            // Accepted gap (Linux): excluding a repository's own root here means a submodule checkout that
            // is deinitialized and re-created (its directory removed, then `git submodule update --init`
            // run again) while a subscription is live never gets its inotify watch re-registered, since the
            // parent directory's recreation event is reported but nothing re-adds a WATCH ROOT, only new
            // non-root directories go through classification/registration. The recreation itself still
            // fires one refresh (the parent's own report is an accepted event), and this heals on the next
            // subscription (a scope switch, a reload, or a Retry), the same self-healing story the
            // repository-map snapshot gap in `attemptInstallLocked` already accepts; excluding repository
            // roots here is what keeps every OTHER already-covered root from being reclassified as if it
            // were a brand-new, possibly-ignored directory on every ordinary event beneath it.
            path != repository.workingDir
        else { return false }
        guard !(classifiedDirectories[repository.workingDir]?.contains(path) ?? false) else { return false }
        let ignored = ignoreSets[repository.workingDir] ?? []
        return !ignored.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    #if os(Linux)
        /// Whether `path` is a directory under any repository's `refs/` tree (`<gitDir>/refs` or
        /// `<commonDir>/refs`), the shape a slash-containing branch name (`refs/heads/feature/x`) or a
        /// fetch (`refs/remotes/origin/...`) creates. Kept separate from `isUnclassifiedNewDirectory`,
        /// which resolves a candidate to a repository's WORKING directory only and so never matches a path
        /// under its git or common dir at all.
        private func isNewDirectoryUnderRefs(_ path: String) -> Bool {
            guard Self.pathIsDirectory(path) else { return false }
            return repositories.contains { repository in
                [repository.gitDir, repository.commonDir].compactMap { $0 }
                    .map { ($0 as NSString).appendingPathComponent("refs") }
                    .contains { path == $0 || path.hasPrefix($0 + "/") }
            }
        }

        /// If `path` is a WORKING-tree directory this repository already classified as not ignored,
        /// reported again by an event (the shape a delete-then-recreate, or a prepared subtree moved back
        /// into place, produces), forgets that classification for `path` and every already-classified path
        /// beneath it, reverting it to unclassified so `isUnclassifiedNewDirectory` matches it again on
        /// this same pass. Mirrors `isUnclassifiedNewDirectory`'s repository resolution and root exclusion
        /// exactly, but requires the OPPOSITE classification state: already classified, not newly seen.
        /// Every entry `classifiedDirectories` holds was classified non-ignored (`classifyNewDirectories`
        /// only ever records the non-ignored half of what it classifies), so membership here already
        /// implies "not ignored" with no separate ignore-set check needed.
        private func forgetStaleClassificationIfRecreated(_ path: String) {
            guard Self.pathIsDirectory(path) else { return }
            guard
                let repository = WorkspaceWatchEventAcceptance.deepestWorkingDirMatch(
                    forChangedPath: path, repositories: eventAcceptanceRepositories()),
                path != repository.workingDir
            else { return }
            guard var classified = classifiedDirectories[repository.workingDir], classified.contains(path) else { return }
            classified.subtract(classified.filter { $0 == path || $0.hasPrefix(path + "/") })
            classifiedDirectories[repository.workingDir] = classified
        }
    #endif

    /// A repository's `.gitignore` (at any depth), repo-level exclude file, or `config`/`config.worktree`
    /// changing invalidates that repository's ignore set; refreshed before the acceptance check runs so
    /// this same event, and every one after it, are judged against the new rules rather than the ones in
    /// force before the edit. `config`/`config.worktree` matter because either can set or change
    /// `core.excludesFile`, an external gitignore `--exclude-standard` (and so this ignore listing) honors
    /// exactly like `.gitignore`; the file `core.excludesFile` itself points at is not watched (see
    /// `SpacesDeviceWorkspaceWatchRepositoryMap.watchPaths`'s doc comment for that accepted gap), but a
    /// `config` edit that changes WHICH file it names, or turns the setting on or off, must still refresh.
    /// Every one of these repo-level files is checked under BOTH `gitDir` and `commonDir`: for an ordinary
    /// repository they are the same path, but a linked worktree's shared files (`info/exclude`, `config`)
    /// live at `<commonDir>/...` (shared with every other worktree of the same repository), not
    /// `<gitDir>/...` (a worktree's own `gitDir`, `<main>/.git/worktrees/<name>`, has no `info/exclude` of
    /// its own, though it does have its own `config.worktree` when `extensions.worktreeConfig` is set).
    private func refreshIgnoreSetIfGitignoreChanged(forChangedPath path: String, needsMapRebuild: inout Bool) {
        for repository in repositories {
            // A non-git repository has no git dir and no ignore set to refresh.
            guard let gitDir = repository.gitDir, let commonDir = repository.commonDir else { continue }
            let isRepoLevelExclude =
                path == (gitDir as NSString).appendingPathComponent("info/exclude")
                || path == (commonDir as NSString).appendingPathComponent("info/exclude")
            let isGitignore = path.hasPrefix(repository.workingDir + "/") && (path as NSString).lastPathComponent == ".gitignore"
            let isConfig =
                ["config", "config.worktree"].contains { name in
                    path == (gitDir as NSString).appendingPathComponent(name) || path == (commonDir as NSString).appendingPathComponent(name)
                }
            // Accepted gap: the index (`<gitDir>/index`) is not one of these invalidators, so `git add -f`
            // on a file inside an already-ignored directory leaves that directory in the ignore set; the
            // now-tracked file's later edits are dropped (and, on Linux, never get an inotify descriptor)
            // until the next reinstall (a scope switch, a reload, or a Retry). Force-adding a file inside
            // an ignored directory is an unusual workflow, and refreshing on every index write would cost
            // one `ls-files` spawn per `git add` or commit in the ordinary, non-force-added steady state.
            guard isRepoLevelExclude || isGitignore || isConfig else { continue }
            let oldIgnored = ignoreSets[repository.workingDir] ?? []
            let newIgnored: Set<String>
            do {
                // A failed re-listing here must not silently keep `oldIgnored`: on Linux, a rule that just
                // stopped excluding a directory would leave that directory permanently unwatched with no
                // signal that anything is wrong, since the ignore set on file never changes to reflect it.
                // Treat this exactly like a classification failure instead (see `failClassification`'s doc
                // comment): stop the watcher, record the error, and force a full recompute so the caller's
                // next frame surfaces it through `currentStartError()` and the Retry affordance.
                newIgnored = try Self.ignoredDirectories(workingDir: repository.workingDir, gitClient: gitClient)
            } catch {
                failClassification(error)
                return
            }
            ignoreSets[repository.workingDir] = newIgnored
            // A previous classification was made under the OLD ignore rules: once they change, a directory
            // this repository already called "classified" can be wrong in either direction (newly ignored,
            // or newly unignored), so it must be re-examined the next time it, or something under it, is
            // reported rather than trusted forever.
            classifiedDirectories[repository.workingDir] = []
            #if os(Linux)
                guard newIgnored != oldIgnored else { continue }
                // A directory that just became ignored keeps every inotify descriptor beneath it: inotify
                // has no per-descriptor "stop watching" call this class uses elsewhere, so there is no
                // targeted way to drop just those. A directory that just became UNignored has no descriptor
                // at all. A full reinstall applies the new ignore set in both directions at once (the walk
                // inside `linuxWatchPaths` skips the newly ignored trees and `classifyNewDirectories`/the
                // install-time walk register the newly unignored ones from scratch), which is simpler and
                // safer than adding a per-descriptor removal API to `FileSystemWatcher` for what is, in
                // practice, a rare `.gitignore` edit. Deferred to `needsMapRebuild` rather than run inline
                // here: `handleFileSystemEvent`'s caller runs one reinstall after its whole acceptance loop
                // regardless of which reason (or both at once, for a `config` write that changes the
                // ignore set and records a new submodule) requested it, so this never doubles up with the
                // submodule-tracking reinstall below for the same event batch. No explicit
                // `pendingTouched`/`armDebounce()` call is needed here either: the caller already arms the
                // debounce, with a full touch, once its loop and any resulting reinstall are done.
                needsMapRebuild = true
                return
            #endif
        }
    }

    /// Whether a changed path currently names a directory: used to spot a newly created directory that
    /// needs classifying, since a directory created (or moved in) after install has no ignore-set entry
    /// on either platform, and no inotify watch of its own on Linux, until something classifies it. There
    /// is no per-path event-type flag on `FileSystemWatcher.onChange` to test for "this was a create"
    /// directly, so every reported path is stat'd; `isUnclassifiedNewDirectory` is what actually narrows
    /// the result down to the candidates worth spending an ignore-listing spawn on.
    /// `lstat`, not `FileManager.fileExists(atPath:isDirectory:)` (which follows symlinks via `stat`): a
    /// directory SYMLINK must never be treated as a directory candidate here. On Linux, `inotify_add_watch`
    /// itself follows a symlink target, so classifying and registering one could watch a directory outside
    /// the workspace entirely, or alias an already-watched repository's own descriptor (the watch table is
    /// keyed by watch descriptor, not path, so a symlink resolving to an existing watched directory would
    /// overwrite that descriptor's path mapping and misattribute its later events to whichever path was
    /// registered last). FSEvents never follows a symlink either, so this keeps the directory-candidate
    /// rule consistent across both platforms rather than only mattering on Linux.
    private static func pathIsDirectory(_ path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFDIR
    }

    /// Whether ANY entry exists at `path` at all (file, directory, or symlink), via `lstat` so a symlink
    /// itself always counts without following it to its target. Used only to detect a `.git` entry (a
    /// plain directory for an ordinary repository, or a gitfile for a submodule checkout) landing directly
    /// inside a directory this watch just registered; see `classifyNewDirectories`'s Linux return value.
    private static func pathExists(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
    }

    /// Classifies newly created directories against their repository's ignore rules, on every platform:
    /// macOS never ran this before (FSEvents needs no per-directory watch registration, so nothing forced
    /// the classification to happen), which let a build directory created after install go unclassified
    /// forever and accept every event under it. Grouped by repository (same matching
    /// `handleFileSystemEvent`'s acceptance pass uses) and run once per batch per repository, never once
    /// per candidate: only a directory-creation event ever carries a directory path in the first place,
    /// the (typically far more numerous) file-write events that follow inside it never do, so this never
    /// scales with burst size the way a per-event ignore-listing spawn would.
    ///
    /// A non-git repository has no ignore set to check against, so every candidate under it is accepted
    /// outright. On Linux, the non-ignored subset is registered with the watcher (`addPaths`), since
    /// inotify is not recursive and has no watch of its own until this adds one. macOS needs no equivalent
    /// registration step: FSEvents already watches the whole workspace root recursively from install.
    ///
    /// On Linux, the TOP-LEVEL candidates are classified FIRST, before any expansion into descendants:
    /// `ls-files --ignored --directory` reports only the shallowest ignored ancestor (`node_modules/`,
    /// never `node_modules/x`), so expanding an ignored root's whole on-disk subtree before ever
    /// classifying it would walk, and worse register with inotify, every descendant of a directory that
    /// should never have been watched at all, e.g. an `npm install` inside a freshly created, `.gitignore`d
    /// `node_modules`. Only the non-ignored top-level candidates are expanded, and that expansion is
    /// classified again the same way, since a descendant can be separately ignored by its own rule even
    /// when its ancestor is not.
    ///
    /// If classification itself throws (the ignore-listing spawn fails despite the chunking in
    /// `classifyIgnored`, or git fails outright), the affected directories' ignore status, and on Linux
    /// their inotify coverage, can never be established from here; silently leaving them dark until the
    /// next full reinstall would be a silent loss of live-refresh coverage that the caller has no way to
    /// know about. `failClassification` instead treats this exactly like an install failure: an `addPaths`
    /// failure (e.g. the inotify watch limit) is recorded the same way, so the next touched-driven
    /// recompute re-reads `lastStartErrorText` (via `currentStartError()`) and carries it into that frame.
    ///
    /// Returns, on Linux, whether any directory this call registered with the watcher already contains a
    /// `.git` entry directly inside it (always `false` on macOS, which never registers directories here).
    /// `git submodule update --init` into an absent checkout directory can `mkdir` it and write its gitfile
    /// microseconds later, before this method ever runs; inotify only reports the `mkdir` on the parent's
    /// watch, and by the time this registers `sub`'s own watch, the gitfile create already happened and is
    /// never separately delivered, so `isRepositoryMapInvalidatingPath`'s `.git`-anywhere-under-a-mapped-
    /// working-dir rule never fires for it. The caller checks this return value to force the same map
    /// rebuild directly instead.
    private func classifyNewDirectories(_ candidates: [String]) -> Bool {
        #if os(Linux)
            var registeredDirectoryContainingGit = false
        #endif
        // The DEEPEST (longest) working-dir match, not just the first repository whose working dir
        // happens to prefix `candidate`: a candidate under an initialized submodule must be attributed to
        // the submodule, never the superproject, whose `ls-files` never lists paths under a gitlink and
        // would leave the candidate permanently out of the submodule's own ignore set.
        let byRepository = Dictionary(grouping: candidates) { candidate in
            WorkspaceWatchEventAcceptance.deepestWorkingDirMatch(forChangedPath: candidate, repositories: eventAcceptanceRepositories())?.workingDir
                ?? resolvedWorkspaceRoot
        }
        for (workingDir, paths) in byRepository {
            let isGitRepository = repositories.first { $0.workingDir == workingDir }?.gitDir != nil
            guard isGitRepository else {
                // Every candidate under a non-git repository is accepted outright (no ignore rules to
                // check), so it is already fully classified: remembering it here stops a repeated event
                // under it from re-running this branch (and, on Linux, re-registering it) forever.
                classifiedDirectories[workingDir, default: []].formUnion(paths)
                #if os(Linux)
                    let directoriesToRegister = expandedWithDescendants(paths, skipping: [])
                    registerWithWatcher(directoriesToRegister)
                    if directoriesToRegister.contains(where: { Self.pathExists(($0 as NSString).appendingPathComponent(".git")) }) {
                        registeredDirectoryContainingGit = true
                    }
                #endif
                continue
            }
            do {
                let topLevel = try Self.classifyIgnored(paths, workingDir: workingDir, gitClient: gitClient)
                if !topLevel.ignored.isEmpty { ignoreSets[workingDir, default: []].formUnion(topLevel.ignored) }
                classifiedDirectories[workingDir, default: []].formUnion(topLevel.nonIgnored)
                #if os(Linux)
                    guard !topLevel.nonIgnored.isEmpty else { continue }
                    // inotify only reports a newly created (or moved-in) tree's TOP directory, never its
                    // pre-existing descendants: none of them individually had a watch, or a parent with
                    // one, at creation time, so a `mkdir -p`-style multi-level tree needs every descendant
                    // expanded into the candidate set here, keeping the "a few spawns per batch per
                    // repository" property this method's own doc comment calls out even though the
                    // pathspec list can now be larger.
                    let descendants = expandedWithDescendants(topLevel.nonIgnored, skipping: ignoreSets[workingDir] ?? [])
                    let expanded = try Self.classifyIgnored(descendants, workingDir: workingDir, gitClient: gitClient)
                    if !expanded.ignored.isEmpty { ignoreSets[workingDir, default: []].formUnion(expanded.ignored) }
                    classifiedDirectories[workingDir, default: []].formUnion(expanded.nonIgnored)
                    registerWithWatcher(expanded.nonIgnored)
                    if expanded.nonIgnored.contains(where: { Self.pathExists(($0 as NSString).appendingPathComponent(".git")) }) {
                        registeredDirectoryContainingGit = true
                    }
                #endif
            } catch {
                failClassification(error)
                #if os(Linux)
                    return registeredDirectoryContainingGit
                #else
                    return false
                #endif
            }
        }
        #if os(Linux)
            return registeredDirectoryContainingGit
        #else
            return false
        #endif
    }

    /// Treats a classification-spawn failure exactly like an install failure (see `classifyNewDirectories`'s
    /// doc comment for why silent degradation is not an option): stops and drops the watcher, records the
    /// error text, and forces one all-touched firing so a subscriber's next recompute surfaces the error
    /// through `currentStartError()` and the visible Retry affordance. Must run on `queue`.
    private func failClassification(_ error: any Error) {
        watcher?.stop()
        watcher = nil
        lastStartErrorText = Self.annotatedErrorText(for: "\(error)")
        pendingTouched = Touched(all: true, directories: [])
        armDebounce()
    }

    #if os(Linux)
        /// Expands `candidates` (freshly reported top-level directory paths) to include every descendant
        /// directory already on disk, via the same plain `FileManager` walk `linuxWatchPaths` uses at
        /// install time: inotify never separately reports a pre-existing descendant's own creation once its
        /// parent already exists at event time, so registering only the reported top misses everything
        /// beneath it. `skipping` prunes descending into a directory already known to be ignored, the same
        /// optimization the install-time walk applies; a brand-new nested ignored directory not yet in
        /// `skipping` is still walked into here, but is caught by the combined ignore-listing call this
        /// feeds into afterward.
        private func expandedWithDescendants(_ candidates: [String], skipping ignored: Set<String>) -> [String] {
            var expanded: Set<String> = []
            for candidate in candidates { Self.enumerateDirectories(under: candidate, skipping: ignored, into: &expanded) }
            return Array(expanded)
        }
    #endif

    /// Batch size for one `ignoredDirectories(limitedTo:)` spawn: keeps a single exec's argument list well
    /// under the OS's argument-length ceiling even for a large moved-in tree (a fresh `node_modules`,
    /// expanded to every on-disk descendant by `expandedWithDescendants`, can run into the thousands),
    /// which would otherwise risk an opaque E2BIG failure for the WHOLE batch rather than just costing a
    /// few more, smaller spawns.
    private static let pathspecChunkSize = 500

    /// Runs `ignoredDirectories(limitedTo:)` over `pathspecs` in batches of `pathspecChunkSize`, unioning
    /// the results, so an unbounded candidate list can never overflow a single spawn's argument list.
    private static func ignoredDirectoriesChunked(
        _ pathspecs: [String], workingDir: String, gitClient: RemoteWorkspaceGitClient
    ) throws -> Set<String> {
        var ignored: Set<String> = []
        for start in stride(from: 0, to: pathspecs.count, by: pathspecChunkSize) {
            let chunk = Array(pathspecs[start..<min(start + pathspecChunkSize, pathspecs.count)])
            ignored.formUnion(try Self.ignoredDirectories(workingDir: workingDir, gitClient: gitClient, limitedTo: chunk))
        }
        return ignored
    }

    /// The same `ls-files --others --ignored --directory` listing the install path takes for a whole
    /// repository, restricted to the candidates as pathspecs (chunked, see `ignoredDirectoriesChunked`). A
    /// candidate counts as ignored when it EQUALS or lies under (a `"/"`-prefixed descendant of) any
    /// reported entry, not just on an exact string match: `--directory` reports only the shallowest
    /// ignored ancestor (`node_modules/`, never `node_modules/x`), so an exact match would call every
    /// deeper candidate "not ignored" and, on Linux, register it with inotify even though its whole
    /// ancestor tree is ignored. Not `git check-ignore`: its NUL-terminated `-z` form is only accepted
    /// together with `--stdin`, and the git client has no way to feed stdin, while its newline form
    /// C-quotes unusual names, which `ls-files -z` never does. Not `private`: exercised directly by
    /// `SpacesDeviceWorkspaceWatchTests` as a pure function of a real repository fixture, without needing a
    /// real filesystem watcher.
    static func classifyIgnored(
        _ paths: [String], workingDir: String, gitClient: RemoteWorkspaceGitClient
    ) throws -> (ignored: [String], nonIgnored: [String]) {
        let ignored = try Self.ignoredDirectoriesChunked(paths, workingDir: workingDir, gitClient: gitClient)
        func isIgnored(_ path: String) -> Bool { ignored.contains { path == $0 || path.hasPrefix($0 + "/") } }
        return (paths.filter(isIgnored), paths.filter { !isIgnored($0) })
    }

    #if os(Linux)
        private func registerWithWatcher(_ paths: [String]) {
            guard !paths.isEmpty else { return }
            do {
                try watcher?.addPaths(paths)
            } catch {
                lastStartErrorText = Self.annotatedErrorText(for: "\(error)")
            }
        }
    #endif

    /// Snapshot of the current repository map in `WorkspaceWatchEventAcceptance.Repository` shape.
    private func eventAcceptanceRepositories() -> [WorkspaceWatchEventAcceptance.Repository] {
        repositories.map {
            WorkspaceWatchEventAcceptance.Repository(
                workingDir: $0.workingDir, gitDir: $0.gitDir, commonDir: $0.commonDir, ancestorWorkingDirs: $0.ancestorWorkingDirs)
        }
    }

    /// Arms the debounce on the first accepted event of a burst, or extends it on every event after:
    /// `debounceInterval` after the latest one, never later than `debounceCeiling` after the burst's
    /// first. Must run on `queue`.
    private func armDebounce() {
        let now = Date()
        if burstStartedAt == nil { burstStartedAt = now }
        let elapsedSinceBurstStart = now.timeIntervalSince(burstStartedAt ?? now)
        let delay = min(debounceInterval, max(0, debounceCeiling - elapsedSinceBurstStart))
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.fireDebounce() }
        debounceTimer = timer
        timer.resume()
    }

    /// Hands the accumulated touched set to every registered handler and clears it. Must run on `queue`;
    /// handlers themselves are called synchronously here (never re-entering `queue`), matching the type
    /// doc's confinement note. Every directory in `pendingTouched` was matched in resolved-root form (see
    /// `resolvedWorkspaceRoot`'s doc comment), so each is rewritten back to `workspaceRoot`'s form here,
    /// once, before a handler (and, through it, a producer's `RepositoryTouchedSet`/contribution cache keyed
    /// by the given `workspace.dir`) ever sees it.
    private func fireDebounce() {
        let touched = pendingTouched
        pendingTouched = .none
        burstStartedAt = nil
        debounceTimer = nil
        let unresolved = Touched(all: touched.all, directories: Set(touched.directories.map(unresolveTouchedDirectory)))
        for handler in handlers.values { handler(unresolved) }
    }

    /// Rewrites a resolved-root-prefixed directory back to the caller's given `workspaceRoot` form: an
    /// exact match on `resolvedWorkspaceRoot` becomes `workspaceRoot`, and a `resolvedWorkspaceRoot + "/"`
    /// prefix has that prefix swapped for `workspaceRoot + "/"`. A no-op (returns `path` unchanged) whenever
    /// `resolvedWorkspaceRoot` equals `workspaceRoot` (no symlink in the recorded root) or `path` does not
    /// fall under the resolved root at all (a repository whose git dir or common dir lives entirely outside
    /// the workspace root, which is never rewritten since nothing outside the workspace root has a
    /// caller-given form to translate back to).
    /// `realpath(3)`, not Foundation's `resolvingSymlinksInPath()`: on macOS the latter deliberately
    /// keeps `/var`, `/tmp`, and `/etc` in their symlinked spelling (it strips the `/private` prefix
    /// again), while FSEvents reports the `/private/...` form, which is exactly the mismatch this
    /// resolution exists to remove. A path `realpath` cannot resolve (it does not exist yet) is kept as
    /// given; the install then fails on the watcher itself and reports that. Not `private`: also called
    /// from `SpacesDeviceWorkspaceWatchRepositoryMap.swift`'s `discoverRepository` to resolve each
    /// repository's `gitDir`/`commonDir` the same way, since git reports a linked worktree's or a
    /// submodule's absolute git-dir/common-dir paths in its own spelling, unresolved, and every root
    /// `WorkspaceWatchEventAcceptance` matches a changed path against must be normalized identically or a
    /// symlinked workspace silently drops every git-dir event for that repository.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func unresolveTouchedDirectory(_ path: String) -> String {
        guard resolvedWorkspaceRoot != workspaceRoot else { return path }
        if path == resolvedWorkspaceRoot { return workspaceRoot }
        if path.hasPrefix(resolvedWorkspaceRoot + "/") { return workspaceRoot + path.dropFirst(resolvedWorkspaceRoot.count) }
        return path
    }
}
