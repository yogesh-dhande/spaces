import Foundation

/// Device-runtime worktree discovery, owned by the daemon.
///
/// Worktree discovery acts on the device's own filesystem and database, so it
/// belongs to `spacesd` (which runs on every device, including headless remotes),
/// not the GUI — a thin client that cannot act on remote devices. The service
/// reconciles worktree-backed workspaces in two ways:
///
/// - A startup scan catches worktrees created, removed, or branch-switched while
///   the daemon was not running. This is cross-platform (pure git + store).
/// - An FSEvents watcher per local git project re-runs the scan when the repo's
///   `HEAD` or `worktrees/` metadata changes. FSEvents is macOS-only; a Linux
///   backend will be added behind the same surface.
///
/// Each scan writes through `SQLiteStore`, which announces `databaseDidChange`, so
/// the GUI sidebar and remote overview subscribers refresh without any direct
/// coupling to this service.
@MainActor
public final class WorktreeDiscoveryService {
    private let databasePath: String
    private let onError: (@Sendable (any Error) -> Void)?
    private var started = false

    #if os(macOS)
        private struct Watch {
            let projectDir: String
            let watcher: FileSystemWatcher
        }
        private var watchers: [String: Watch] = [:]
    #endif

    public init(databasePath: String, onError: (@Sendable (any Error) -> Void)? = nil) {
        self.databasePath = databasePath
        self.onError = onError
    }

    /// Runs the catch-up scan and, on macOS, installs the per-project watchers.
    public func start() {
        guard !started else { return }
        started = true
        scan(projectID: nil)
        refreshWatchers()
    }

    public func stop() {
        started = false
        #if os(macOS)
            for watch in watchers.values { watch.watcher.stop() }
            watchers.removeAll()
        #endif
    }

    /// Reconciles the installed watchers to the current set of local git projects.
    /// The daemon calls this on `databaseDidChange` so a newly created or removed
    /// git project starts or stops being watched. A freshly added project is also
    /// scanned once, since it may already contain worktrees.
    public func refreshWatchers() {
        #if os(macOS)
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
                    guard let commonDirectory = await Self.commonDirectory(projectDir: projectDir) else { continue }
                    guard self.started, self.watchers[projectID] == nil else { continue }
                    self.installWatcher(projectID: projectID, projectDir: projectDir, commonDirectory: commonDirectory)
                    self.scan(projectID: projectID)
                }
            }
        #endif
    }

    #if os(macOS)
        private func installWatcher(projectID: String, projectDir: String, commonDirectory: String) {
            let watcher = FileSystemWatcher(paths: [commonDirectory], latency: 1) { [weak self] changedPaths in
                guard Self.changedPathsAffectWorktrees(changedPaths, commonDirectory: commonDirectory) else { return }
                Task { @MainActor [weak self] in self?.scan(projectID: projectID) }
            }
            do {
                try watcher.start()
                watchers[projectID] = Watch(projectDir: projectDir, watcher: watcher)
            } catch {
                onError?(error)
            }
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
    #endif

    /// Builds a transient store/orchestrator off the main actor and reconciles
    /// worktree-backed workspaces for the given project (all projects when nil).
    private func scan(projectID: String?) {
        let databasePath = databasePath
        let onError = onError
        Task.detached(priority: .utility) {
            do {
                let store = try SQLiteStore(path: databasePath)
                let orchestrator = WorkspaceOrchestrator(store: store)
                _ = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: projectID)
            } catch {
                onError?(error)
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
