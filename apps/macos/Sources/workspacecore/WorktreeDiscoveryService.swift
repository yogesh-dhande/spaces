import Foundation

/// The lifecycle surface `WorktreeDiscoveryService` needs from a filesystem watcher.
/// Kept internal so tests can substitute a watcher whose `start()` blocks, verifying
/// that a slow install never stalls the main actor. `start()` is async because the
/// real watcher runs its (potentially slow) FSEvents/inotify setup off the caller's
/// thread; the service awaits it so a stall suspends the actor instead of blocking it.
protocol FileSystemWatching: Sendable {
    func start() async throws
    func stop()
}

extension FileSystemWatcher: FileSystemWatching {}

/// Device-runtime worktree discovery, owned by the daemon.
///
/// Worktree discovery acts on the device's own filesystem and database, so it
/// belongs to `spacesd` (which runs on every device, including headless remotes),
/// not the GUI — a thin client that cannot act on remote devices. The service
/// reconciles worktree-backed workspaces in two ways:
///
/// - A startup scan catches worktrees created, removed, or branch-switched while
///   the daemon was not running. This is cross-platform (pure git + store).
/// - A `FileSystemWatcher` per local git project re-runs the scan when the repo's
///   `HEAD` or `worktrees/` metadata changes (FSEvents on macOS, inotify on Linux).
///
/// Each scan writes through `SQLiteStore`, which announces `databaseDidChange`, so
/// the GUI sidebar and remote overview subscribers refresh without any direct
/// coupling to this service.
@MainActor public final class WorktreeDiscoveryService {
    private struct Watch {
        let projectDir: String
        let commonDirectory: String
        /// The directories handed to the watcher. On Linux (non-recursive inotify)
        /// this is the git common dir plus the `worktrees/` tree, so it changes as
        /// worktrees are added or removed; on macOS it is the single recursive root.
        let watchedDirectories: [String]
        let watcher: any FileSystemWatching
    }

    /// Builds a watcher for a project's directories. Injected so tests can substitute
    /// a slow-starting watcher; production always uses `liveWatcherFactory`.
    typealias WatcherFactory = @Sendable (
        _ paths: [String], _ latency: TimeInterval, _ onChange: @escaping @Sendable ([String]) -> Void
    ) -> any FileSystemWatching

    private let databasePath: String
    private let onError: (@Sendable (any Error) -> Void)?
    private let makeWatcher: WatcherFactory
    private var watchers: [String: Watch] = [:]
    // Projects whose install is in flight. Installing a watcher suspends across
    // `commonDirectory`/`watchDirectories`/`start`, so without a synchronous
    // reservation a `databaseDidChange` storm would fire many overlapping
    // `refreshWatchers` passes that each build a second FSEventStream for the same
    // not-yet-installed project (a per-pass fd leak). This set is inserted into before
    // the first suspension and cleared when the install settles, so a project installs
    // exactly once regardless of how many passes overlap.
    private var installingProjectIDs: Set<String> = []
    private var started = false
    // Scans are serialized: a worktree mutation emits several filesystem events in
    // quick succession, and overlapping scans would race to create the same
    // workspace row (a UNIQUE (project_id, branch) violation). A scan requested
    // while one is in flight collapses into a single trailing full re-scan.
    private var scanInFlight = false
    private var scanPending = false

    public convenience init(databasePath: String, onError: (@Sendable (any Error) -> Void)? = nil) {
        self.init(databasePath: databasePath, onError: onError, watcherFactory: Self.liveWatcherFactory)
    }

    init(databasePath: String, onError: (@Sendable (any Error) -> Void)? = nil, watcherFactory: @escaping WatcherFactory) {
        self.databasePath = databasePath
        self.onError = onError
        self.makeWatcher = watcherFactory
    }

    private static let liveWatcherFactory: WatcherFactory = { paths, latency, onChange in
        FileSystemWatcher(paths: paths, latency: latency, onChange: onChange)
    }

    /// Runs the catch-up scan and installs the per-project watchers.
    public func start() {
        guard !started else { return }
        started = true
        scan(projectID: nil)
        refreshWatchers()
    }

    public func stop() {
        started = false
        for watch in watchers.values { watch.watcher.stop() }
        watchers.removeAll()
    }

    /// Reconciles the installed watchers to the current set of local git projects.
    /// The daemon calls this on `databaseDidChange` so a newly created or removed
    /// git project starts or stops being watched. A freshly added project is also
    /// scanned once, since it may already contain worktrees.
    public func refreshWatchers() {
        guard started else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let desired = await Self.localGitProjectDirsByID(databasePath: self.databasePath)
            guard self.started else { return }
            for (projectID, watch) in self.watchers where desired[projectID] != watch.projectDir {
                watch.watcher.stop()
                self.watchers[projectID] = nil
            }
            for (projectID, projectDir) in desired where self.watchers[projectID] == nil {
                await self.installWatcher(projectID: projectID, projectDir: projectDir)
                self.scan(projectID: projectID)
            }
        }
    }

    /// Installs a watcher for one project. The git common-dir lookup, directory-list
    /// computation, and the watcher's `start()` all run off the main actor (each can
    /// stall — a git spawn, a slow-filesystem enumeration, FSEvents/inotify IPC under
    /// load), so this method suspends across them rather than blocking the actor.
    ///
    /// Because it suspends, it reserves the project in `installingProjectIDs` before the
    /// first `await`, so overlapping `refreshWatchers` passes install a project exactly
    /// once instead of each racing to build (and leak) a second stream. The
    /// `started` / `watchers[projectID] == nil` invariants are also re-checked after
    /// every suspension as defense in depth.
    private func installWatcher(projectID: String, projectDir: String) async {
        guard started, watchers[projectID] == nil, installingProjectIDs.insert(projectID).inserted else { return }
        defer { installingProjectIDs.remove(projectID) }
        guard let commonDirectory = await Self.commonDirectory(projectDir: projectDir) else { return }
        guard started, watchers[projectID] == nil else { return }
        let watchedDirectories = await Self.watchDirectories(commonDirectory: commonDirectory)
        guard started, watchers[projectID] == nil else { return }
        let watcher = makeWatcher(watchedDirectories, 1) { [weak self] changedPaths in
            guard Self.changedPathsAffectWorktrees(changedPaths, commonDirectory: commonDirectory) else { return }
            Task { @MainActor [weak self] in await self?.handleChange(projectID: projectID) }
        }
        do {
            try await watcher.start()
            guard started, watchers[projectID] == nil else {
                watcher.stop()
                return
            }
            watchers[projectID] = Watch(
                projectDir: projectDir, commonDirectory: commonDirectory, watchedDirectories: watchedDirectories, watcher: watcher)
        } catch { onError?(error) }
    }

    /// The `started` guard is the stop() safety net: a watcher callback that fires
    /// while the watcher's async teardown is still draining must not trigger a scan or
    /// reinstall after the service has stopped.
    private func handleChange(projectID: String) async {
        guard started else { return }
        scan(projectID: projectID)
        await reinstallWatcherIfWatchSetChanged(projectID: projectID)
    }

    /// On Linux the inotify watch set includes each `worktrees/<name>/` directory,
    /// so adding or removing a worktree changes which directories must be watched;
    /// reinstall the watcher when that set drifts. On macOS the recursive FSEvents
    /// root never changes, so this is a no-op.
    private func reinstallWatcherIfWatchSetChanged(projectID: String) async {
        #if os(Linux)
            guard started, let watch = watchers[projectID] else { return }
            let desired = await Self.watchDirectories(commonDirectory: watch.commonDirectory)
            guard started, let watch = watchers[projectID], desired != watch.watchedDirectories else { return }
            watch.watcher.stop()
            watchers[projectID] = nil
            await installWatcher(projectID: projectID, projectDir: watch.projectDir)
        #endif
    }

    /// The directories to watch for a project's git common dir. FSEvents watches the
    /// single root recursively; inotify is not recursive, so the Linux build watches
    /// the common dir (for `HEAD` and `worktrees/` creation) plus the `worktrees/`
    /// tree (for worktree add/remove and per-worktree `HEAD`). Runs off the main actor:
    /// the Linux branch enumerates the `worktrees/` tree, which can block on a slow
    /// filesystem, and the trivial macOS branch shares the seam for uniformity.
    private static func watchDirectories(commonDirectory: String) async -> [String] {
        await Task.detached(priority: .utility) {
            #if os(macOS)
                return [commonDirectory]
            #else
                var directories = [commonDirectory]
                let worktreesDirectory = commonDirectory + "/worktrees"
                guard isDirectory(worktreesDirectory) else { return directories }
                directories.append(worktreesDirectory)
                for entry in ((try? FileManager.default.contentsOfDirectory(atPath: worktreesDirectory)) ?? []).sorted() {
                    let subdirectory = worktreesDirectory + "/" + entry
                    if isDirectory(subdirectory) { directories.append(subdirectory) }
                }
                return directories
            #endif
        }.value
    }

    private nonisolated static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private nonisolated static func localGitProjectDirsByID(databasePath: String) async -> [String: String] {
        await Task.detached(priority: .utility) {
            guard let store = try? SQLiteStore(path: databasePath), let projects = try? store.projects() else { return [:] }
            return Dictionary(projects.filter(\.isGitRepo).map { ($0.id, $0.dir) }, uniquingKeysWith: { first, _ in first })
        }.value
    }

    private nonisolated static func commonDirectory(projectDir: String) async -> String? {
        await Task.detached(priority: .utility) { GitClient().commonDirectory(path: projectDir) }.value
    }

    /// Builds a transient store/orchestrator off the main actor and reconciles
    /// worktree-backed workspaces for the given project (all projects when nil).
    /// Serialized so overlapping event-driven scans cannot race on row creation;
    /// a request that arrives mid-scan triggers one trailing full re-scan.
    private func scan(projectID: String?) {
        guard !scanInFlight else {
            scanPending = true
            return
        }
        scanInFlight = true
        let databasePath = databasePath
        let onError = onError
        Task { @MainActor [weak self] in
            await Task.detached(priority: .utility) {
                do {
                    let store = try SQLiteStore(path: databasePath)
                    let orchestrator = WorkspaceOrchestrator(store: store)
                    _ = try await orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: projectID)
                } catch { onError?(error) }
            }.value
            guard let self else { return }
            self.scanInFlight = false
            if self.scanPending {
                self.scanPending = false
                self.scan(projectID: nil)
            }
        }
    }

    /// Only git worktree metadata should trigger a reconcile; object/index/log
    /// churn from ordinary commits must not. Matches the shared `HEAD` (main
    /// checkout branch switch) and anything under `worktrees/` (linked worktree
    /// add, remove, or branch switch).
    public nonisolated static func changedPathsAffectWorktrees(_ paths: [String], commonDirectory: String) -> Bool {
        let head = commonDirectory + "/HEAD"
        let worktreesDir = commonDirectory + "/worktrees"
        return paths.contains { $0 == head || $0 == worktreesDir || $0.hasPrefix(worktreesDir + "/") }
    }
}
