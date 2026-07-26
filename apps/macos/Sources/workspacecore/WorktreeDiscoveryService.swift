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

    /// A project whose watcher install failed, held out of the install path until its
    /// directory becomes reachable again.
    ///
    /// Without this, every `databaseDidChange`-driven `refreshWatchers()` pass retried each
    /// failed install: a `git rev-parse --git-common-dir` spawn, a watcher create, and an
    /// error report per unwatchable project per pass, for as long as the daemon ran.
    private struct Quarantine {
        /// The project directory the failed install targeted. A refresh that sees a different
        /// directory for this project drops the quarantine: the project row points somewhere
        /// else, so the recorded failure no longer describes it.
        let projectDir: String
        /// Whether `projectDir` existed when the install failed. Re-arming keys off the
        /// *transition* from absent to present, not off "currently reachable": a project that
        /// was reachable when it failed — a directory that is no longer a git repo, or a
        /// watcher the OS refused for reasons other than the path (FSEvents capacity
        /// exhaustion) — reads as reachable on every later pass, so a "currently reachable"
        /// rule would retry the expensive path forever, which is the storm this exists to
        /// stop. Such a project is re-armed only by its project row changing or by the daemon
        /// restarting.
        var directoryExists: Bool
    }

    /// Builds a watcher for a project's directories. Injected so tests can substitute
    /// a slow-starting watcher; production always uses `liveWatcherFactory`.
    typealias WatcherFactory =
        @Sendable (_ paths: [String], _ latency: TimeInterval, _ onChange: @escaping @Sendable ([String]) -> Void) -> any FileSystemWatching

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
    // Projects whose last install attempt failed, keyed by project id. Entries are skipped by
    // `refreshWatchers` and cost one `stat`-class directory check per pass until their
    // directory reappears; see `Quarantine`.
    private var quarantines: [String: Quarantine] = [:]
    private var started = false
    // Every `spawnTrackedTask` call not yet finished, keyed by a token minted at spawn time and
    // cleared in the task's own `defer` when it returns. `refreshWatchers`, a watcher's on-change
    // callback, and `scan()` each fire an untracked-looking `Task` that this dictionary makes
    // observable, so `drainInFlightWorkForTesting()` can await the service down to quiescence
    // instead of a test polling watcher counts against a settle window.
    private var inFlightTasks: [UUID: Task<Void, Never>] = [:]
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
        quarantines.removeAll()
    }

    /// Reconciles the installed watchers to the current set of local git projects.
    /// The daemon calls this on `databaseDidChange` so a newly created or removed
    /// git project starts or stops being watched. A freshly added project is also
    /// scanned once, since it may already contain worktrees.
    ///
    /// A project whose install failed is quarantined and skipped here, so a project that
    /// cannot be watched costs one directory check per pass instead of a git spawn, a
    /// watcher create, an error report, and a scan.
    public func refreshWatchers() {
        guard started else { return }
        spawnTrackedTask { [weak self] in
            guard let self else { return }
            let desired = await Self.localGitProjectDirsByID(databasePath: self.databasePath)
            guard self.started else { return }
            for (projectID, watch) in self.watchers where desired[projectID] != watch.projectDir {
                watch.watcher.stop()
                self.watchers[projectID] = nil
            }
            // A quarantine describes one project row pointing at one directory, so a project
            // that was removed or repointed no longer has a recorded failure to honor.
            self.quarantines = self.quarantines.filter { desired[$0.key] == $0.value.projectDir }
            await self.rearmQuarantinesForReturnedDirectories()
            guard self.started else { return }
            for (projectID, projectDir) in desired where self.watchers[projectID] == nil && self.quarantines[projectID] == nil {
                await self.installWatcher(projectID: projectID, projectDir: projectDir)
                self.scan(projectID: projectID)
            }
        }
    }

    /// The entire per-pass cost of a quarantined project: one directory-existence check,
    /// batched with every other quarantined project into a single off-main-actor task
    /// (deliberately off the actor because even `stat` can block on a wedged mount — the very
    /// situation that produces quarantines). Lifts the quarantine on the transition from
    /// absent to present, so a deleted or unmounted project directory that returns is
    /// installed on that same pass without a restart, while a project whose directory never
    /// went away is never re-attempted from here.
    private func rearmQuarantinesForReturnedDirectories() async {
        guard !quarantines.isEmpty else { return }
        let existsByProjectID = await Self.directoriesExist(quarantines.mapValues(\.projectDir))
        for (projectID, exists) in existsByProjectID {
            guard var quarantine = quarantines[projectID] else { continue }
            if exists, !quarantine.directoryExists {
                quarantines[projectID] = nil
            } else {
                quarantine.directoryExists = exists
                quarantines[projectID] = quarantine
            }
        }
    }

    /// Records a failed install so later refresh passes skip it, capturing whether the project
    /// directory exists at the moment of failure — the baseline the re-arm transition is
    /// measured against.
    private func quarantineFailedInstall(projectID: String, projectDir: String) async {
        let directoryExists = await Self.directoryExists(projectDir)
        guard started, watchers[projectID] == nil else { return }
        quarantines[projectID] = Quarantine(projectDir: projectDir, directoryExists: directoryExists)
    }

    /// Spawns a task tracked in `inFlightTasks`, keyed by a token minted before the task exists and
    /// removed in a `defer` once the body returns. The token is generated first, then the task is
    /// created and immediately stored under it in one synchronous main-actor statement — the task
    /// never needs to reference its own `Task` handle (a self-referencing `var task; task = Task {
    /// ... task ... }` capture is what Swift 6 strict concurrency flags as a data race, since a
    /// mutable local captured by an escaping `Sendable` closure is assumed reachable from another
    /// thread even though, isolation-wise, it never actually is here). Callable only from the main
    /// actor: a non-isolated caller (a filesystem watcher's on-change closure, which fires on its own
    /// queue) must hop onto the main actor first, e.g. `Task { @MainActor in self?.spawnTrackedTask
    /// { ... } } }`.
    private func spawnTrackedTask(_ body: @escaping @Sendable @MainActor () async -> Void) {
        let taskID = UUID()
        inFlightTasks[taskID] = Task { @MainActor [weak self] in
            defer { self?.inFlightTasks[taskID] = nil }
            await body()
        }
    }

    /// Awaits every task this service has spawned and not yet finished. Loops because completing
    /// one can enqueue another — a refresh that discovers a new project also schedules its install
    /// and scan; a scan with `scanPending` set re-schedules a trailing full re-scan — so a single
    /// snapshot of the dictionary is not enough to know the service is quiescent. Returns once none
    /// remain: the seam a test drains after storming `refreshWatchers()` instead of polling watcher
    /// counts against a settle window.
    func drainInFlightWorkForTesting() async { while let (_, task) = inFlightTasks.first { await task.value } }

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
    ///
    /// Both ways the install can fail — the project is not a resolvable git repo, or the
    /// watcher's stream cannot be created — quarantine the project, so this expensive path
    /// runs once per failure rather than once per refresh pass.
    private func installWatcher(projectID: String, projectDir: String) async {
        guard started, watchers[projectID] == nil, installingProjectIDs.insert(projectID).inserted else { return }
        defer { installingProjectIDs.remove(projectID) }
        guard let commonDirectory = await Self.commonDirectory(projectDir: projectDir) else {
            await quarantineFailedInstall(projectID: projectID, projectDir: projectDir)
            return
        }
        guard started, watchers[projectID] == nil else { return }
        let watchedDirectories = await Self.watchDirectories(commonDirectory: commonDirectory)
        guard started, watchers[projectID] == nil else { return }
        let watcher = makeWatcher(watchedDirectories, 1) { [weak self] changedPaths in
            guard Self.changedPathsAffectWorktrees(changedPaths, commonDirectory: commonDirectory) else { return }
            // This callback fires on the watcher's own queue (FSEvents/inotify), never the main
            // actor, so it hops over before calling the main-actor-only `spawnTrackedTask`. The hop
            // itself is a scheduling gap, not a data race (only main-actor code ever touches
            // `inFlightTasks`), but it means a change delivered in the instant between this call and
            // the hop actually running is not yet visible to `drainInFlightWorkForTesting()`. No test
            // exercises `drainInFlightWorkForTesting()` against a live filesystem watcher's onChange,
            // only against `refreshWatchers()`/`scan()`, which spawn their tracked task directly on
            // the main actor with no such gap.
            Task { @MainActor [weak self] in self?.spawnTrackedTask { [weak self] in await self?.handleChange(projectID: projectID) } }
        }
        do {
            try await watcher.start()
            guard started, watchers[projectID] == nil else {
                watcher.stop()
                return
            }
            // Accepted staleness window: these re-checks confirm the service is still
            // running and no watcher exists for the project, but do not re-validate that
            // `projectDir`/`commonDirectory` still exist on disk. A project moved or
            // deleted while a slow `start()` was suspended can briefly publish a watcher
            // for the stale path. This is deliberately tolerated: the next
            // `databaseDidChange` refresh reconciles it (`refreshWatchers` stops any
            // watcher whose `projectDir` no longer matches the desired set), and DB
            // changes are frequent, so the window self-heals quickly.
            watchers[projectID] = Watch(
                projectDir: projectDir, commonDirectory: commonDirectory, watchedDirectories: watchedDirectories, watcher: watcher)
        } catch {
            // Reported here, once per real install attempt. Quarantining is what keeps that
            // bounded: an unwatchable project is not attempted again until its directory
            // returns, so a persistent failure cannot produce an unbounded error stream.
            onError?(error)
            await quarantineFailedInstall(projectID: projectID, projectDir: projectDir)
        }
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

    /// Existence check for one project directory, run off the main actor for the same reason
    /// the batch check is.
    private nonisolated static func directoryExists(_ path: String) async -> Bool {
        await Task.detached(priority: .utility) { isDirectory(path) }.value
    }

    /// Existence check for every quarantined project's directory in one off-main-actor task,
    /// so a refresh pass pays one hop regardless of how many projects are quarantined.
    private nonisolated static func directoriesExist(_ pathsByProjectID: [String: String]) async -> [String: Bool] {
        await Task.detached(priority: .utility) { pathsByProjectID.mapValues { isDirectory($0) } }.value
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
        spawnTrackedTask { [weak self] in
            await Task.detached(priority: .utility) {
                do {
                    let store = try SQLiteStore(path: databasePath)
                    let orchestrator = WorkspaceOrchestrator(store: store)
                    _ = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: projectID)
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
