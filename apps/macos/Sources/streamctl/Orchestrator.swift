import Darwin
import Foundation
import appctl

public final class SpaceshipOrchestrator {
    private enum ExtractedBrowserFocusOutcome {
        case focused
        case staleMapping
        case notMapped
    }

    private struct ResolvedBrowserSession {
        let index: Int
        let prefix: String
        let session: BrowserSession
    }

    private struct BrowserWindowScanResult {
        let windows: [WindowRecord]
        let tabIndexByWindowAndURL: [String: Int]
    }

    private struct CachedScannedBrowserTabTarget {
        let tabIndex: Int
        let browserPrefixes: [String]
    }

    private struct BrowserWindowScanCacheEntry {
        let browserPrefixes: [String]
        let refreshedAt: Date
        let scanResult: BrowserWindowScanResult
    }

    private let store: SQLiteStore
    private let configStore: ConfigStore
    private let git: GitClient
    private let yabai: YabaiAdapter
    private let iterm: Iterm2Adapter
    private let chrome: ChromeAdapter
    private let browserWindowScanDebounceInterval: TimeInterval
    private let currentDate: () -> Date
    private let projectsRootDirectoryURL: URL?
    private let workspacesRootDirectoryURL: URL?
    private let workspaceLifecycleLock = NSLock()
    private var workspaceLifecycleInFlight: Set<String> = []
    private let windowNavigationLock = NSLock()
    private var windowNavigationIndexByWorkspace: [String: Int] = [:]
    private let browserScanCacheLock = NSLock()
    private var browserWindowScanCacheByWorkspace: [String: BrowserWindowScanCacheEntry] = [:]

    public init(
        store: SQLiteStore, configStore: ConfigStore, projectsRootDirectory: URL? = nil, workspacesRootDirectory: URL? = nil,
        git: GitClient = .init(), yabai: YabaiAdapter = .init(), iterm: Iterm2Adapter = .init(), chrome: ChromeAdapter = .init(),
        browserWindowScanDebounceInterval: TimeInterval = PollingConstants.browserWindowScanDebounceInterval, currentDate: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.configStore = configStore
        projectsRootDirectoryURL = projectsRootDirectory
        self.git = git
        self.yabai = yabai
        self.iterm = iterm
        self.chrome = chrome
        self.workspacesRootDirectoryURL = workspacesRootDirectory
        self.browserWindowScanDebounceInterval = browserWindowScanDebounceInterval
        self.currentDate = currentDate
        if ProcessInfo.processInfo.environment["DEBUG"] == "1" { fputs("spaceship: DEBUG=1 enabled (browser scan/focus profiling active)\n", stderr) }
    }

    @discardableResult public func syncConfig() throws -> AppConfig {
        var config = try configStore.load()
        var normalizedProjects: [NormalizedProject] = []
        var normalizedConfigs: [ProjectConfig] = []
        var removedInvalid = false
        var updatedPaths = false
        for project in config.projects {
            do {
                let normalized = try normalize(project: project)
                normalizedProjects.append(normalized)
                normalizedConfigs.append(normalized.config)
                if normalizePath(project.dir) != normalized.config.dir { updatedPaths = true }
            } catch {
                fputs("spaceship: skipped project due to error: \(error.localizedDescription)\n", stderr)
                removedInvalid = true
            }
        }
        config.projects = normalizedConfigs
        let keepIDs = Set(normalizedProjects.map(\.id))
        let existing = try store.projects()
        for project in existing where !keepIDs.contains(project.id) { try store.deleteProject(id: project.id) }
        for project in normalizedProjects {
            try store.upsert(project: project.record)
            try ensureDefaultWorkspace(for: project.record)
            try ensureWorkspaceSettings(for: project.record, config: project.config)
        }
        if removedInvalid || updatedPaths { try configStore.save(config) }
        return config
    }

    public func listProjects() throws -> [ProjectSummary] {
        return try store.projects().map {
            ProjectSummary(id: $0.id, name: $0.name, dir: $0.dir, isGitRepo: $0.isGitRepo, defaultBranch: $0.defaultBranch)
        }
    }

    @discardableResult public func updateEditorPreference(_ editor: EditorPreference?) throws -> AppConfig {
        var config = try configStore.load()
        config.editor = editor
        try configStore.save(config)
        return config
    }

    public func listWorkspaces(projectID: String, includeArchived: Bool = false) throws -> [WorkspaceSummary] {
        let records = try store.workspaces(projectID: projectID, includeArchived: includeArchived)
        return records.map {
            WorkspaceSummary(
                id: $0.id, name: $0.name, branch: $0.branch, dir: $0.dir, isRunning: $0.isRunning, isArchived: $0.isArchived, isDefault: $0.isDefault)
        }
    }

    public func suggestedWorkspaceName(projectID: String) throws -> String {
        guard let project = try store.project(id: projectID) else { throw SpaceshipError.missingProject(dir: projectID) }
        let existingNames = Set(try store.workspaces(projectID: project.id, includeArchived: true).map(\.name))
        for candidate in SpaceshipOrchestrator.workspaceFoodNames where !existingNames.contains(candidate) { return candidate }
        throw SpaceshipError.invalidArgument(message: "No available workspace names remain for project \(project.name).")
    }

    public func gitBranchOptions(projectID: String) throws -> [String] {
        guard let project = try store.project(id: projectID) else { throw SpaceshipError.missingProject(dir: projectID) }
        guard project.isGitRepo else { return [] }
        return git.branchOptions(path: project.dir)
    }

    public func workspaceGitTrackedFileActivity(workspaceID: String) throws -> GitTrackedFileActivity? {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard project.isGitRepo else { return nil }
        return git.trackedFileActivity(path: workspace.dir)
    }

    public func projectConfig(projectID: String) throws -> ProjectConfig? {
        let config = try configStore.load()
        guard let project = try store.project(id: projectID) else { return nil }
        return config.projects.first { normalizePath($0.dir) == project.dir }
    }

    public func workspaceSettings(workspaceID: String) throws -> WorkspaceSettings? {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let config = try projectConfig(projectID: project.id)
        return try loadWorkspaceSettings(project: project, workspace: workspace, config: config)
    }

    public func updateWorkspaceSettings(workspaceID: String, update: (inout WorkspaceSettings) -> Void) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let config = try projectConfig(projectID: project.id)
        guard var existing = try loadWorkspaceSettings(project: project, workspace: workspace, config: config) else {
            throw SpaceshipError.missingProject(dir: project.dir)
        }
        let previous = existing
        update(&existing)
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: existing.stopScript)
        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: existing.ports)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: existing.processes)
        try store.setWorkspaceStatusChecks(workspaceID: workspace.id, checks: existing.statusChecks)
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: existing.browserSessions)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: nowISO8601())
        let trackedProcesses = try store.runningProcesses(workspaceID: workspace.id)
        let trackedWindows = try store.windows(workspaceID: workspace.id)
        let hasRuntimeIndicators = !trackedProcesses.isEmpty || !trackedWindows.isEmpty
        if !workspace.isRunning && hasRuntimeIndicators {
            let launchedAt = workspace.lastLaunchedAt ?? nowISO8601()
            try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: launchedAt)
        }
        if workspace.isRunning || hasRuntimeIndicators {
            try applyWorkspaceSettingsUpdate(project: project, workspace: workspace, previous: previous, updated: existing)
        }
    }

    public func addProject(dir: String) throws -> ProjectRecord {
        var config = try configStore.load()
        let normalizedDir = normalizePath(dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedDir, isDirectory: &isDir), isDir.boolValue else {
            throw SpaceshipError.invalidArgument(message: "Project directory not found: \(normalizedDir)")
        }
        if config.projects.contains(where: { normalizePath($0.dir) == normalizedDir }) {
            throw SpaceshipError.projectAlreadyExists(dir: normalizedDir)
        }
        config.projects.append(ProjectConfig(dir: normalizedDir))
        try configStore.save(config)
        let normalized = try normalize(project: ProjectConfig(dir: normalizedDir))
        try store.upsert(project: normalized.record)
        try ensureDefaultWorkspace(for: normalized.record)
        return normalized.record
    }

    public func addProject(gitURL: String) throws -> ProjectRecord {
        let trimmedURL = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { throw SpaceshipError.invalidArgument(message: "Git repository URL is required.") }
        let inferredName = inferredProjectName(from: trimmedURL)
        let projectDirname = sanitizeDirname(inferredName, fallback: "project")
        let destination = projectsRootDirectory().appending(path: projectDirname, directoryHint: .isDirectory)
        let normalizedDestination = normalizePath(destination.path)

        let config = try configStore.load()
        if config.projects.contains(where: { normalizePath($0.dir) == normalizedDestination }) {
            throw SpaceshipError.projectAlreadyExists(dir: normalizedDestination)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw SpaceshipError.invalidArgument(message: "Project directory already exists: \(normalizedDestination)")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git.clone(url: trimmedURL, destination: destination.path)
        return try addProject(dir: destination.path)
    }

    public func updateProjectConfig(_ updated: ProjectConfig) throws {
        var config = try configStore.load()
        let normalizedDir = normalizePath(updated.dir)
        let idx = config.projects.firstIndex { normalizePath($0.dir) == normalizedDir }
        guard let idx else { throw SpaceshipError.missingProject(dir: normalizedDir) }
        let previous = config.projects[idx]
        var normalizedUpdated = updated
        normalizedUpdated.dir = normalizedDir
        config.projects[idx] = normalizedUpdated
        try configStore.save(config)
        let normalized = try normalize(project: normalizedUpdated)
        try store.upsert(project: normalized.record)
        try ensureDefaultWorkspace(for: normalized.record)
        try syncDefaultWorkspaceSettingsIfTemplateBased(project: normalized.record, previousConfig: previous, updatedConfig: normalized.config)
    }

    public func updateProjectConfig(projectID: String, update: (inout ProjectConfig) -> Void) throws {
        var config = try configStore.load()
        let normalizedDir = normalizePath(projectID)
        let idx = config.projects.firstIndex { normalizePath($0.dir) == normalizedDir }
        guard let idx else { throw SpaceshipError.missingProject(dir: normalizedDir) }
        let previous = config.projects[idx]
        var updated = config.projects[idx]
        update(&updated)
        updated.dir = normalizedDir
        config.projects[idx] = updated
        try configStore.save(config)
        let normalized = try normalize(project: updated)
        try store.upsert(project: normalized.record)
        try ensureDefaultWorkspace(for: normalized.record)
        try syncDefaultWorkspaceSettingsIfTemplateBased(project: normalized.record, previousConfig: previous, updatedConfig: normalized.config)
    }

    public func removeProject(dir: String) throws {
        var config = try configStore.load()
        let normalizedDir = normalizePath(dir)
        config.projects.removeAll { normalizePath($0.dir) == normalizedDir }
        try configStore.save(config)
        if let project = try store.project(dir: normalizedDir) {
            let workspaces = try store.workspaces(projectID: project.id, includeArchived: true)
            try removeManagedGitWorktreesIfNeeded(project: project, workspaces: workspaces)
            try store.deleteProject(id: project.id)
            try removeManagedGitWorkspaceDirectoriesIfNeeded(project: project)
            try removeManagedProjectDirectoryIfNeeded(project: project)
        }
    }

    public func createWorkspace(projectID: String, name: String, branch: String? = nil, targetBranch: String? = nil, directoryName: String? = nil)
        throws -> WorkspaceRecord
    {
        guard let project = try store.project(id: projectID) else { throw SpaceshipError.missingProject(dir: projectID) }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw SpaceshipError.invalidArgument(message: "Workspace name is required.") }
        let trimmedDirectoryName = directoryName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBranch: String?
        let resolvedTargetBranch: String?
        if project.isGitRepo {
            guard let trimmedBranch, !trimmedBranch.isEmpty else {
                throw SpaceshipError.invalidArgument(message: "Branch name is required for git projects.")
            }
            resolvedBranch = trimmedBranch
            resolvedTargetBranch = try resolveWorkspaceTargetBranch(project: project, targetBranch: targetBranch)
        } else {
            if let trimmedDirectoryName, !trimmedDirectoryName.isEmpty {
                throw SpaceshipError.invalidArgument(message: "Directory name override is only supported for git projects.")
            }
            resolvedBranch = nil
            resolvedTargetBranch = nil
        }
        if let existing = try store.workspace(projectID: projectID, name: trimmedName) {
            if !existing.isArchived { throw SpaceshipError.workspaceAlreadyExists(project: project.name, workspace: trimmedName) }
            let revivedDir: String
            let revivedDirname: String?
            let revivedBranch: String?
            if project.isGitRepo {
                guard let branchName = resolvedBranch else {
                    throw SpaceshipError.invalidArgument(message: "Branch name is required for git projects.")
                }
                let dirname = try makeWorkspaceDirname(project: project, existingDirname: existing.dirname, requestedDirname: trimmedDirectoryName)
                revivedDirname = dirname
                let worktreeRoot = try worktreeRoot(project: project)
                try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
                revivedDir = worktreeRoot.appendingPathComponent(dirname, isDirectory: true).path
                if !FileManager.default.fileExists(atPath: revivedDir) {
                    try git.createWorktree(path: project.dir, worktreePath: revivedDir, branch: branchName, targetBranch: resolvedTargetBranch)
                }
                revivedBranch = branchName
            } else {
                revivedDir = project.dir
                revivedDirname = nil
                revivedBranch = nil
            }
            let revived = WorkspaceRecord(
                id: existing.id, projectID: project.id, name: trimmedName, dir: revivedDir, dirname: revivedDirname, branch: revivedBranch,
                isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
            try store.upsert(workspace: revived)
            try seedWorkspaceSettings(project: project, workspace: revived)
            let config = try configStore.load()
            let portDefinitions = try store.workspacePortDefinitions(workspaceID: revived.id)
            _ = try PortAllocator(store: store).allocatePorts(workspaceID: revived.id, definitions: portDefinitions, range: config.portRange)
            if let projectConfig = try projectConfig(projectID: projectID), let script = projectConfig.setupScript, !script.isEmpty {
                let namedPorts = try store.workspacePortsNamed(workspaceID: revived.id)
                let env = buildWorkspaceEnv(project: project, workspace: revived, namedPorts: namedPorts)
                try runScript(applyEnvVars(script, env: env), cwd: revived.dir)
            }
            return revived
        }
        let workspaceDir: String
        let workspaceDirname: String?
        let workspaceBranch: String?
        if project.isGitRepo {
            guard let branchName = resolvedBranch else { throw SpaceshipError.invalidArgument(message: "Branch name is required for git projects.") }
            let dirname = try makeWorkspaceDirname(project: project, existingDirname: nil, requestedDirname: trimmedDirectoryName)
            workspaceDirname = dirname
            let worktreeRoot = try worktreeRoot(project: project)
            try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
            workspaceDir = worktreeRoot.appendingPathComponent(dirname, isDirectory: true).path
            try git.createWorktree(path: project.dir, worktreePath: workspaceDir, branch: branchName, targetBranch: resolvedTargetBranch)
            workspaceBranch = branchName
        } else {
            workspaceDir = project.dir
            workspaceDirname = nil
            workspaceBranch = nil
        }
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, name: trimmedName, dir: workspaceDir, dirname: workspaceDirname, branch: workspaceBranch,
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        try seedWorkspaceSettings(project: project, workspace: workspace)

        let appConfig = try configStore.load()
        let portDefinitions = try store.workspacePortDefinitions(workspaceID: workspace.id)
        _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, definitions: portDefinitions, range: appConfig.portRange)

        if let config = try projectConfig(projectID: projectID), let script = config.setupScript, !script.isEmpty {
            let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
            let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
            try runScript(applyEnvVars(script, env: env), cwd: workspaceDir)
        }

        return workspace
    }

    private func resolveWorkspaceTargetBranch(project: ProjectRecord, targetBranch: String?) throws -> String {
        if let targetBranch = targetBranch?.trimmingCharacters(in: .whitespacesAndNewlines), !targetBranch.isEmpty { return targetBranch }
        if let configured = project.defaultBranch, !configured.isEmpty { return configured }
        if git.branchExists(path: project.dir, branch: "main") || git.remoteBranchExists(path: project.dir, branch: "main") { return "main" }
        if git.branchExists(path: project.dir, branch: "master") || git.remoteBranchExists(path: project.dir, branch: "master") { return "master" }
        throw SpaceshipError.invalidArgument(message: "Target branch is required for git projects.")
    }

    public func launchWorkspace(workspaceID: String) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) { try launchWorkspaceUnlocked(workspaceID: workspaceID) }
    }

    public func restartWorkspace(workspaceID: String) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            try stopWorkspaceUnlocked(workspaceID: workspaceID)
            try launchWorkspaceUnlocked(workspaceID: workspaceID)
        }
    }

    private func launchWorkspaceUnlocked(workspaceID: String) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isArchived else { throw SpaceshipError.invalidArgument(message: "Workspace is archived.") }
        let hasTrackedRuntime = try hasTrackedRuntimeIndicators(workspaceID: workspace.id)
        guard !(workspace.isRunning || hasTrackedRuntime) else {
            throw SpaceshipError.invalidArgument(message: "Workspace is already running. Use restart.")
        }
        let config = try loadWorkspaceSettings(project: project, workspace: workspace, config: try projectConfig(projectID: project.id))
        let portDefinitions = try store.workspacePortDefinitions(workspaceID: workspace.id)
        let ports = try store.workspacePorts(workspaceID: workspace.id)
        if ports.count != portDefinitions.count {
            let portRange = try configStore.load().portRange
            _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, definitions: portDefinitions, range: portRange)
        } else {
            try PortAllocator(store: store).reserveExistingPorts(workspaceID: workspace.id)
        }

        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: try store.workspacePortsNamed(workspaceID: workspace.id))

        var newWindows: [WindowRecord] = []
        var windowSnapshot = try yabai.listWindows()

        if let config {
            try launchProcesses(workspace: workspace, templates: config.processes, env: env)
            let capturedTerminals = try captureNewWindows(
                snapshot: windowSnapshot, role: "terminal", appName: "iTerm2", workspaceID: workspace.id, orderOffset: 200)
            newWindows.append(contentsOf: capturedTerminals)
            let ensuredTerminals = try terminalWindowsFromRunningProcesses(workspace: workspace, existingWindows: newWindows)
            newWindows.append(contentsOf: ensuredTerminals)
            windowSnapshot = try yabai.listWindows()

            let browserSessionResult = try ensureBrowserSessions(
                project: project, workspace: workspace, sessions: config.browserSessions, env: env, extractOnAttach: true)
            try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: browserSessionResult.sessions)
            newWindows.append(contentsOf: browserSessionResult.windows)
            newWindows.append(
                contentsOf: try captureNewWindows(
                    snapshot: windowSnapshot, role: "browser", appName: "Google Chrome", workspaceID: workspace.id, orderOffset: 0))
            windowSnapshot = try yabai.listWindows()
        }

        if let editor = try configStore.load().editor {
            let editorApps = editorAppNames(editor)
            try EditorLauncher.open(editor: editor, directory: workspace.dir)
            var editorWindows = try captureNewWindows(
                snapshot: windowSnapshot, role: "editor", appNames: editorApps, workspaceID: workspace.id, orderOffset: 100)
            if editorWindows.isEmpty, let focused = try yabai.focusedWindow(), editorApps.contains(focused.app) {
                editorWindows = [
                    WindowRecord(
                        id: UUID().uuidString, workspaceID: workspace.id, app: focused.app, title: focused.title, windowID: focused.id, role: "editor",
                        orderIndex: 100, lastSeenAt: nowISO8601())
                ]
            }
            newWindows.append(contentsOf: editorWindows)
        }

        try store.deleteWindows(workspaceID: workspace.id)
        var index = 0
        let browserWindowIDsWithTarget = Set(
            newWindows.compactMap { window -> Int? in
                guard window.role == "browser", window.targetURL != nil else { return nil }
                return window.windowID
            })
        var seenKeys = Set<String>()
        let uniqueWindows = newWindows.filter { window in
            if window.role == "browser", window.targetURL == nil, let id = window.windowID, browserWindowIDsWithTarget.contains(id) { return false }
            let key = windowTrackingKey(window)
            if seenKeys.contains(key) { return false }
            seenKeys.insert(key)
            return true
        }
        for window in uniqueWindows {
            let stored = WindowRecord(
                id: window.id, workspaceID: window.workspaceID, app: window.app, title: window.title, targetURL: window.targetURL,
                windowID: window.windowID, role: window.role, orderIndex: index, lastSeenAt: window.lastSeenAt)
            index += 1
            try store.upsert(window: stored)
        }

        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: nowISO8601())
        setWindowNavigationIndex(nil, workspaceID: workspace.id)
    }

    public func stopWorkspace(workspaceID: String) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) { try stopWorkspaceUnlocked(workspaceID: workspaceID) }
    }

    private func stopWorkspaceUnlocked(workspaceID: String) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let windows = try trackedWindows(workspaceID: workspace.id)
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace, config: try projectConfig(projectID: project.id))
        let processes = try store.runningProcesses(workspaceID: workspace.id)
        for process in processes { if let pid = resolvedRuntimePID(for: process) { terminateProcessGroup(pid: pid) } }
        if let script = settings?.stopScript?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty {
            try runScript(applyEnvVars(script, env: env), cwd: workspace.dir)
        }
        for process in processes { if let windowID = process.windowID, process.terminalApp == "iTerm2" { _ = try? iterm.closeWindow(id: windowID) } }
        var closedWindowIDs = Set<Int>()
        for window in windows {
            if window.role == "browser" {
                closeTrackedBrowserTab(window)
                continue
            }
            if let id = window.windowID, !closedWindowIDs.contains(id) {
                closedWindowIDs.insert(id)
                _ = try? yabai.closeWindow(id: id)
            }
        }
        try store.deleteRunningProcesses(workspaceID: workspace.id)
        try store.deleteWindows(workspaceID: workspace.id)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: false, launchedAt: workspace.lastLaunchedAt)
        setWindowNavigationIndex(nil, workspaceID: workspace.id)
    }

    public func archiveWorkspace(workspaceID: String) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) { try archiveWorkspaceUnlocked(workspaceID: workspaceID) }
    }

    private func archiveWorkspaceUnlocked(workspaceID: String) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isDefault else { throw SpaceshipError.invalidArgument(message: "Default workspace cannot be archived.") }
        try stopWorkspaceUnlocked(workspaceID: workspaceID)
        if project.isGitRepo {
            do { try git.removeWorktree(path: project.dir, worktreePath: workspace.dir) } catch { if !isMissingWorktreeError(error) { throw error } }
        }
        try PortAllocator(store: store).releasePorts(workspaceID: workspace.id)
        try store.updateWorkspaceArchived(id: workspace.id, isArchived: true)
    }

    private func hasTrackedRuntimeIndicators(workspaceID: String) throws -> Bool {
        let trackedProcesses = try store.runningProcesses(workspaceID: workspaceID)
        let trackedWindows = try store.windows(workspaceID: workspaceID)
        return !trackedProcesses.isEmpty || !trackedWindows.isEmpty
    }

    private func withWorkspaceLifecycleLock<T>(workspaceID: String, operation: () throws -> T) throws -> T {
        workspaceLifecycleLock.lock()
        if workspaceLifecycleInFlight.contains(workspaceID) {
            workspaceLifecycleLock.unlock()
            throw SpaceshipError.invalidArgument(message: "Workspace action is already in progress.")
        }
        workspaceLifecycleInFlight.insert(workspaceID)
        workspaceLifecycleLock.unlock()

        defer {
            workspaceLifecycleLock.lock()
            workspaceLifecycleInFlight.remove(workspaceID)
            workspaceLifecycleLock.unlock()
        }
        return try operation()
    }

    public func runningProcesses(workspaceID: String) throws -> [RunningProcessRecord] { try store.runningProcesses(workspaceID: workspaceID) }

    public func runStatusChecks(workspaceID: String) throws -> [StatusResult] {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard let config = try loadWorkspaceSettings(project: project, workspace: workspace, config: try projectConfig(projectID: project.id)) else {
            return []
        }
        let processes = try store.runningProcesses(workspaceID: workspaceID)
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspaceID)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        var results: [StatusResult] = []
        for check in config.statusChecks {
            guard let process = processes.first(where: { $0.templateName == check.process }) else { continue }
            let resolvedCommand = applyEnvVars(check.command, env: env)
            let outcome = try runCommandWithTimeout(command: resolvedCommand, cwd: workspace.dir, timeout: check.timeout, env: env)
            let status = outcome.exitCode == 0 ? "green" : "red"
            let result = StatusResult(
                processID: process.id, checkName: check.name ?? check.process, status: status, message: outcome.output.isEmpty ? nil : outcome.output,
                lastRunAt: nowISO8601())
            try store.upsert(statusResult: result)
            results.append(result)
            
            // Handle onExit behavior for failed status checks
            if outcome.exitCode != 0 {
                try handleStatusCheckFailure(workspaceID: workspaceID, process: process, check: check, result: result)
            }
        }
        return results
    }
    
    private func handleStatusCheckFailure(workspaceID: String, process: RunningProcessRecord, check: StatusCheckDefinition, result: StatusResult) throws {
        switch check.onExit {
        case .none:
            // Do nothing - just log the failure
            break
            
        case .notify:
            // Show notification to the user
            let notification = NSUserNotification()
            notification.title = "Status Check Failed"
            notification.informativeText = "Process '\(process.templateName)' check '\(result.checkName)' failed"
            if let message = result.message {
                notification.subtitle = message
            }
            NSUserNotificationCenter.default.deliver(notification)
            
        case .restart:
            // Restart the process
            try restartFailedProcess(workspaceID: workspaceID, process: process, check: check, result: result)
        }
    }
    
    private func restartFailedProcess(workspaceID: String, process: RunningProcessRecord, check: StatusCheckDefinition, result: StatusResult) throws {
        // Log the restart attempt
        fputs("spaceship: Restarting process '\(process.templateName)' due to failed status check '\(result.checkName)'\n", stderr)
        
        // Show notification about restart
        let notification = NSUserNotification()
        notification.title = "Process Restarting"
        notification.informativeText = "Process '\(process.templateName)' is being restarted due to failed status check"
        if let message = result.message {
            notification.subtitle = "Reason: \(message)"
        }
        NSUserNotificationCenter.default.deliver(notification)
        
        // Terminate the existing process group if PID exists
        if let pid = process.pid {
            terminateProcessGroup(pid: pid)
        }
        
        // Mark the process as exited in the database
        let updatedProcess = RunningProcessRecord(
            id: process.id, workspaceID: process.workspaceID, templateName: process.templateName,
            command: process.command, terminalApp: process.terminalApp, windowID: process.windowID,
            pid: process.pid, status: .exited, logPath: process.logPath,
            lastOutputAt: process.lastOutputAt, startedAt: process.startedAt,
            exitedAt: nowISO8601()
        )
        try store.upsert(runningProcess: updatedProcess)
        
        // Restart the process in a new terminal
        try restartProcessInTerminal(workspaceID: workspaceID, process: process)
    }
    
    private func restartProcessInTerminal(workspaceID: String, process: RunningProcessRecord) throws {
        let (_, workspace) = try resolveWorkspace(id: workspaceID)
        let _ = try store.workspacePortsNamed(workspaceID: workspaceID)
        
        // Open new terminal and run the command
        let escapedCommand = process.command.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedDir = workspace.dir.replacingOccurrences(of: "\"", with: "\\\"")
        let fullCommand = "cd \"\(escapedDir)\" && \(escapedCommand)"
        
        let windowInfo = try iterm.openWindowAndRun(command: fullCommand)
        let windowID = windowInfo.id
        
        // Update the process record with new window ID and running status
        let restartedProcess = RunningProcessRecord(
            id: process.id, workspaceID: process.workspaceID, templateName: process.templateName,
            command: process.command, terminalApp: "iTerm2", windowID: windowID,
            pid: nil, status: .running, logPath: process.logPath,
            lastOutputAt: nil, startedAt: nowISO8601(), exitedAt: nil
        )
        try store.upsert(runningProcess: restartedProcess)
    }

    public func statusResults(processID: String) throws -> [StatusResult] { try store.statusResults(processID: processID) }

    public func windows(workspaceID: String) throws -> [WindowRecord] { try trackedWindows(workspaceID: workspaceID) }

    public func refreshWorkspaceWindows(workspaceID: String) throws {
        _ = try trackedWindows(workspaceID: workspaceID)
        try pruneMissingWindows(workspaceID: workspaceID)
        guard let workspace = try store.workspace(id: workspaceID), workspace.isRunning else { return }
        let hasRuntimeIndicators = try hasTrackedRuntimeIndicators(workspaceID: workspaceID)
        if !hasRuntimeIndicators {
            try store.updateWorkspaceRunning(id: workspaceID, isRunning: false, launchedAt: workspace.lastLaunchedAt)
            setWindowNavigationIndex(nil, workspaceID: workspaceID)
        }
    }

    public func refreshAllWorkspaceWindows() throws {
        for project in try store.projects() {
            let workspaces = try store.workspaces(projectID: project.id, includeArchived: false)
            for workspace in workspaces { try refreshWorkspaceWindows(workspaceID: workspace.id) }
        }
    }

    public func workspacePorts(workspaceID: String) throws -> [Int] { try store.workspacePorts(workspaceID: workspaceID) }

    public func workspacePortsNamed(workspaceID: String) throws -> [(port: Int, name: String)] {
        try store.workspacePortsNamed(workspaceID: workspaceID)
    }

    public func openWorkspaceEditor(workspaceID: String) throws {
        let (_, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isArchived else { throw SpaceshipError.invalidArgument(message: "Workspace is archived.") }
        guard let editor = try configStore.load().editor, editor != .none else {
            throw SpaceshipError.configError(message: "Preferred editor is not configured.")
        }
        let snapshot = try yabai.listWindows()
        try EditorLauncher.open(editor: editor, directory: workspace.dir)
        try attachNewWindows(snapshot: snapshot, workspaceID: workspace.id, role: "editor", appNames: editorAppNames(editor), orderOffset: 100)
    }

    public func openWorkspaceTerminal(workspaceID: String) throws {
        let (_, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isArchived else { throw SpaceshipError.invalidArgument(message: "Workspace is archived.") }
        guard iterm.isAvailable() else { throw SpaceshipError.dependencyMissing(message: "iTerm2 is required to open terminal windows.") }
        let snapshot = try yabai.listWindows()
        let escapedDir = workspace.dir.replacingOccurrences(of: "\"", with: "\\\"")
        _ = try iterm.openWindowAndRun(command: "cd \"\(escapedDir)\"")
        try attachNewWindows(snapshot: snapshot, workspaceID: workspace.id, role: "terminal", appName: "iTerm2", orderOffset: 200)
    }

    public func focusWorkspace(workspaceID: String) throws {
        let windows = try trackedWindows(workspaceID: workspaceID)
        var focused = false
        for (idx, window) in windows.enumerated() {
            let ok = focusTrackedWindow(window, workspaceID: workspaceID)
            if ok {
                focused = true
                setWindowNavigationIndex(idx, workspaceID: workspaceID)
                break
            }
        }
        if focused { try setActiveWorkspace(id: workspaceID) }
    }

    public func focusWorkspaceWindow(workspaceID: String, index: Int) throws {
        guard index > 0 else { return }
        let windows = try trackedWindows(workspaceID: workspaceID)
        guard index <= windows.count else { return }
        let targetIndex = index - 1
        let ok = focusTrackedWindow(windows[targetIndex], workspaceID: workspaceID)
        if ok {
            setWindowNavigationIndex(targetIndex, workspaceID: workspaceID)
            try setActiveWorkspace(id: workspaceID)
        }
    }

    public func focusNextWindow(workspaceID: String) throws { try focusWindowRelative(workspaceID: workspaceID, delta: 1) }

    public func focusPreviousWindow(workspaceID: String) throws { try focusWindowRelative(workspaceID: workspaceID, delta: -1) }

    public func workspaceIDForFocusedWindow() throws -> String? {
        guard let focused = try yabai.focusedWindow() else { return nil }
        if focused.app == "Google Chrome", let workspaceID = try focusedChromeWorkspaceID(windowID: focused.id) { return workspaceID }
        return try store.workspaceID(windowID: focused.id)
    }

    private func focusedChromeWorkspaceID(windowID: Int) throws -> String? {
        if chrome.isAvailable(), let activeURL = (try? chrome.frontmostActiveTabURL()) ?? nil {
            var matchingWorkspaceIDs: [String] = []
            for project in try store.projects() {
                let workspaces = try store.workspaces(projectID: project.id, includeArchived: true)
                for workspace in workspaces where workspace.isRunning && !workspace.isArchived {
                    let prefixes = try resolvedBrowserSessionPrefixes(project: project, workspace: workspace)
                    if prefixes.contains(where: { activeURL.hasPrefix($0) }) { matchingWorkspaceIDs.append(workspace.id) }
                }
            }
            if let activeWorkspaceID = try activeWorkspaceID(), matchingWorkspaceIDs.contains(activeWorkspaceID) { return activeWorkspaceID }
            if let firstMatch = matchingWorkspaceIDs.first { return firstMatch }
        }

        let candidates = try store.windows(windowID: windowID).filter { $0.role == "browser" }
        guard !candidates.isEmpty else { return nil }
        let candidateWorkspaceIDs = Array(Set(candidates.map(\.workspaceID)))
        if candidateWorkspaceIDs.count == 1 { return candidateWorkspaceIDs[0] }
        if let activeWorkspaceID = try activeWorkspaceID(), candidateWorkspaceIDs.contains(activeWorkspaceID) { return activeWorkspaceID }
        return candidates.max(by: { lhs, rhs in lhs.lastSeenAt < rhs.lastSeenAt })?.workspaceID
    }

    private func focusWindowRelative(workspaceID: String, delta: Int) throws {
        let windows = try trackedWindows(workspaceID: workspaceID)
        guard !windows.isEmpty else { return }
        let rememberedIndex = windowNavigationIndex(workspaceID: workspaceID)
        let currentIndex: Int?
        if let rememberedIndex, rememberedIndex >= 0, rememberedIndex < windows.count {
            currentIndex = rememberedIndex
        } else {
            currentIndex = try currentFocusedWindowIndex(windows: windows)
        }
        let targetIndex: Int
        if let currentIndex {
            targetIndex = (currentIndex + delta + windows.count) % windows.count
        } else if delta > 0 {
            targetIndex = 0
        } else {
            targetIndex = windows.count - 1
        }
        let ok = focusTrackedWindow(windows[targetIndex], workspaceID: workspaceID)
        if ok {
            setWindowNavigationIndex(targetIndex, workspaceID: workspaceID)
            try setActiveWorkspace(id: workspaceID)
        }
    }

    private func currentFocusedWindowIndex(windows: [WindowRecord]) throws -> Int? {
        if let focused = try yabai.focusedWindow() {
            let candidates = windows.enumerated().filter { $0.element.windowID == focused.id }
            if !candidates.isEmpty {
                if candidates.count == 1 { return candidates[0].offset }
                if focused.app == "Google Chrome", chrome.isAvailable(), let activeURL = (try? chrome.frontmostActiveTabURL()) ?? nil {
                    if let tabMatch = candidates.max(by: { lhs, rhs in
                        browserTabMatchPriority(activeURL: activeURL, targetURL: lhs.element.targetURL)
                            < browserTabMatchPriority(activeURL: activeURL, targetURL: rhs.element.targetURL)
                    }), browserTabMatchPriority(activeURL: activeURL, targetURL: tabMatch.element.targetURL) > 0 {
                        return tabMatch.offset
                    }
                }
                return candidates[0].offset
            }
            if focused.app == "Google Chrome", chrome.isAvailable(), let activeURL = (try? chrome.frontmostActiveTabURL()) ?? nil {
                if let tabMatch = windows.enumerated().max(by: { lhs, rhs in
                    browserTabMatchPriority(activeURL: activeURL, targetURL: lhs.element.targetURL)
                        < browserTabMatchPriority(activeURL: activeURL, targetURL: rhs.element.targetURL)
                }), tabMatch.element.role == "browser", browserTabMatchPriority(activeURL: activeURL, targetURL: tabMatch.element.targetURL) > 0 {
                    return tabMatch.offset
                }
            }
        }
        return nil
    }

    private func browserTabMatchPriority(activeURL: String, targetURL: String?) -> Int {
        guard let targetURL else { return 0 }
        if activeURL == targetURL { return 2 }
        if activeURL.hasPrefix(targetURL) { return 1 }
        return 0
    }

    private func windowNavigationIndex(workspaceID: String) -> Int? {
        windowNavigationLock.lock()
        defer { windowNavigationLock.unlock() }
        return windowNavigationIndexByWorkspace[workspaceID]
    }

    private func setWindowNavigationIndex(_ index: Int?, workspaceID: String) {
        windowNavigationLock.lock()
        if let index {
            windowNavigationIndexByWorkspace[workspaceID] = index
        } else {
            windowNavigationIndexByWorkspace.removeValue(forKey: workspaceID)
        }
        windowNavigationLock.unlock()
    }

    private func focusTrackedWindow(_ window: WindowRecord, workspaceID: String) -> Bool {
        let focusStartedAt = currentDate()
        var focusPath = "yabai"
        if window.role == "browser", let targetURL = window.targetURL, chrome.isAvailable() {
            let extractedOutcome = (try? focusExtractedBrowserWindow(workspaceID: workspaceID, targetURL: targetURL)) ?? .notMapped
            if extractedOutcome == .focused {
                focusPath = "extracted"
                logBrowserFocus(
                    "workspace=\(workspaceID) path=\(focusPath) target=\(targetURL) elapsed_ms=\(elapsedMS(since: focusStartedAt))")
                return true
            }
            if let trackedWindowID = window.windowID {
                let focusedIndexedTrackedWindowTab =
                    (try? focusScannedBrowserTab(workspaceID: workspaceID, windowID: trackedWindowID, targetURL: targetURL)) ?? false
                if focusedIndexedTrackedWindowTab {
                    focusPath = "indexed"
                    logBrowserFocus(
                        "workspace=\(workspaceID) path=\(focusPath) window=\(trackedWindowID) target=\(targetURL) elapsed_ms=\(elapsedMS(since: focusStartedAt))"
                    )
                    return true
                }
                let focusedExactTrackedWindowTab = (try? chrome.focusTab(forExactURL: targetURL, windowID: trackedWindowID)) ?? false
                if focusedExactTrackedWindowTab {
                    focusPath = "tracked_exact"
                    logBrowserFocus(
                        "workspace=\(workspaceID) path=\(focusPath) window=\(trackedWindowID) target=\(targetURL) elapsed_ms=\(elapsedMS(since: focusStartedAt))"
                    )
                    return true
                }
                let focusedTrackedWindowTab = (try? chrome.focusTab(forURLPrefix: targetURL, windowID: trackedWindowID)) ?? false
                if focusedTrackedWindowTab {
                    focusPath = "tracked_prefix"
                    logBrowserFocus(
                        "workspace=\(workspaceID) path=\(focusPath) window=\(trackedWindowID) target=\(targetURL) elapsed_ms=\(elapsedMS(since: focusStartedAt))"
                    )
                    return true
                }
            }
            let focusedExactBrowserTab = (try? chrome.focusTab(forExactURL: targetURL)) ?? false
            if focusedExactBrowserTab {
                focusPath = "global_exact"
                logBrowserFocus("workspace=\(workspaceID) path=\(focusPath) target=\(targetURL) elapsed_ms=\(elapsedMS(since: focusStartedAt))")
                return true
            }
            let focusedBrowserTab = (try? chrome.focusTab(forURLPrefix: targetURL)) ?? false
            if focusedBrowserTab {
                focusPath = "global_prefix"
                logBrowserFocus("workspace=\(workspaceID) path=\(focusPath) target=\(targetURL) elapsed_ms=\(elapsedMS(since: focusStartedAt))")
                return true
            }
            logBrowserFocus(
                "workspace=\(workspaceID) path=browser_fallback_failed target=\(targetURL) elapsed_ms=\(elapsedMS(since: focusStartedAt))")
        }
        guard let id = window.windowID else { return false }
        let focused = (try? yabai.focusWindow(id: id)) ?? false
        logBrowserFocus(
            "workspace=\(workspaceID) path=yabai window=\(id) success=\(focused ? "1" : "0") elapsed_ms=\(elapsedMS(since: focusStartedAt))")
        return focused
    }

    private func trackedWindows(workspaceID: String) throws -> [WindowRecord] {
        let windows = try store.windows(workspaceID: workspaceID).sorted { $0.orderIndex < $1.orderIndex }
        let normalized = normalizedBrowserWindowRows(windows)
        guard chrome.isAvailable(), let (project, workspace) = try? resolveWorkspace(id: workspaceID) else { return normalized }
        let prefixes = try resolvedBrowserSessionPrefixes(project: project, workspace: workspace)
        guard !prefixes.isEmpty else { return normalized }
        guard let scannedBrowserWindows = try? liveBrowserWindows(workspaceID: workspaceID, browserPrefixes: prefixes) else { return normalized }
        let terminalWindows = normalized.filter { $0.role == "terminal" }
        let otherNonBrowserWindows = normalized.filter { $0.role != "browser" && $0.role != "terminal" }
        return scannedBrowserWindows + terminalWindows + otherNonBrowserWindows
    }

    private func resolvedBrowserSessionPrefixes(project: ProjectRecord, workspace: WorkspaceRecord) throws -> [String] {
        let sessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        guard !sessions.isEmpty else { return [] }
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        return resolveBrowserSessions(sessions, env: env).map(\.prefix)
    }

    private func resolveBrowserSessions(_ sessions: [BrowserSession], env: [String: String]) -> [ResolvedBrowserSession] {
        var resolved: [ResolvedBrowserSession] = []
        var seen = Set<String>()
        for (index, session) in sessions.enumerated() {
            guard let rawURL = session.url?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty else { continue }
            let prefix = applyEnvVars(rawURL, env: env)
            guard !prefix.isEmpty, !seen.contains(prefix) else { continue }
            seen.insert(prefix)
            resolved.append(ResolvedBrowserSession(index: index, prefix: prefix, session: session))
        }
        return resolved
    }

    private func extractSessionWindowIfNeeded(
        session: ResolvedBrowserSession, matches: [ChromeWindowMatch], refreshedSessions: inout [BrowserSession]
    ) throws -> Int? {
        if let extractedWindow = session.session.extractedWindow,
            extractedWindow.isValid,
            matches.contains(where: { $0.windowID == extractedWindow.windowID })
        {
            refreshedSessions[session.index].extractedWindow = ExtractedBrowserWindowMapping(
                targetURL: session.prefix, windowID: extractedWindow.windowID, isValid: true)
            return extractedWindow.windowID
        }
        guard let firstMatch = matches.first else { return nil }
        guard let extractedWindowID = try chrome.extractTabToWindow(windowID: firstMatch.windowID, tabIndex: firstMatch.tabIndex) else { return nil }
        refreshedSessions[session.index].extractedWindow = ExtractedBrowserWindowMapping(
            targetURL: session.prefix, windowID: extractedWindowID, isValid: true)
        return extractedWindowID
    }

    private func focusExtractedBrowserWindow(workspaceID: String, targetURL: String) throws -> ExtractedBrowserFocusOutcome {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let sessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        guard !sessions.isEmpty else { return .notMapped }
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: try store.workspacePortsNamed(workspaceID: workspace.id))
        let resolvedSessions = resolveBrowserSessions(sessions, env: env)
        guard !resolvedSessions.isEmpty else { return .notMapped }

        guard
            let matchedSession = resolvedSessions
                .filter({ targetURL.hasPrefix($0.prefix) })
                .max(by: { $0.prefix.count < $1.prefix.count }),
            let extractedWindow = sessions[matchedSession.index].extractedWindow,
            extractedWindow.isValid
        else { return .notMapped }

        let focused = try yabai.focusWindow(id: extractedWindow.windowID)
        guard focused else {
            try markExtractedWindowInvalid(workspaceID: workspace.id, sessions: sessions, index: matchedSession.index)
            return .staleMapping
        }

        let activeURL = try chrome.frontmostActiveTabURL()
        guard let activeURL, browserURLMatchesWorkspace(activeURL, browserPrefixes: resolvedSessions.map(\.prefix)) else {
            try markExtractedWindowInvalid(workspaceID: workspace.id, sessions: sessions, index: matchedSession.index)
            return .staleMapping
        }
        return .focused
    }

    private func markExtractedWindowInvalid(workspaceID: String, sessions: [BrowserSession], index: Int) throws {
        guard sessions.indices.contains(index), let extractedWindow = sessions[index].extractedWindow else { return }
        guard extractedWindow.isValid else { return }
        var updatedSessions = sessions
        updatedSessions[index].extractedWindow = ExtractedBrowserWindowMapping(
            targetURL: extractedWindow.targetURL, windowID: extractedWindow.windowID, isValid: false)
        try store.setWorkspaceBrowserSessions(workspaceID: workspaceID, sessions: updatedSessions)
    }

    private func liveBrowserWindows(workspaceID: String, browserPrefixes: [String], forceRefresh: Bool = false) throws -> [WindowRecord] {
        guard !browserPrefixes.isEmpty else { return [] }
        let refreshedAt = currentDate()
        if !forceRefresh {
            if let cached = cachedBrowserWindows(workspaceID: workspaceID, browserPrefixes: browserPrefixes, now: refreshedAt) {
                let cacheAgeMS = Int(refreshedAt.timeIntervalSince(cached.refreshedAt) * 1000)
                logBrowserFocus("workspace=\(workspaceID) scan_cache_hit age_ms=\(cacheAgeMS) rows=\(cached.scanResult.windows.count)")
                return cached.scanResult.windows
            }
        }
        logBrowserFocus("workspace=\(workspaceID) scan_cache_miss force_refresh=\(forceRefresh ? "1" : "0")")
        let scanResult = try scannedBrowserWindows(workspaceID: workspaceID, browserPrefixes: browserPrefixes)
        cacheBrowserWindows(workspaceID: workspaceID, browserPrefixes: browserPrefixes, refreshedAt: refreshedAt, scanResult: scanResult)
        return scanResult.windows
    }

    private func cachedBrowserWindows(workspaceID: String, browserPrefixes: [String], now: Date) -> BrowserWindowScanCacheEntry? {
        browserScanCacheLock.lock()
        defer { browserScanCacheLock.unlock() }
        guard let entry = browserWindowScanCacheByWorkspace[workspaceID] else { return nil }
        guard entry.browserPrefixes == browserPrefixes else { return nil }
        let elapsed = now.timeIntervalSince(entry.refreshedAt)
        guard elapsed >= 0, elapsed < browserWindowScanDebounceInterval else { return nil }
        return entry
    }

    private func cacheBrowserWindows(workspaceID: String, browserPrefixes: [String], refreshedAt: Date, scanResult: BrowserWindowScanResult) {
        browserScanCacheLock.lock()
        browserWindowScanCacheByWorkspace[workspaceID] = BrowserWindowScanCacheEntry(
            browserPrefixes: browserPrefixes, refreshedAt: refreshedAt, scanResult: scanResult)
        browserScanCacheLock.unlock()
    }

    private func focusScannedBrowserTab(workspaceID: String, windowID: Int, targetURL: String) throws -> Bool {
        let focusStartedAt = currentDate()
        var refreshed = false
        var attempt = 0
        while attempt < 2 {
            attempt += 1
            guard let cachedTarget = cachedScannedBrowserTabTarget(workspaceID: workspaceID, windowID: windowID, targetURL: targetURL) else {
                logBrowserFocus("workspace=\(workspaceID) indexed_miss window=\(windowID) target=\(targetURL) attempt=\(attempt)")
                return false
            }

            let focusByIndexStartedAt = currentDate()
            let focused = try chrome.focusTab(windowID: windowID, tabIndex: cachedTarget.tabIndex)
            logBrowserFocus(
                "workspace=\(workspaceID) indexed_focus window=\(windowID) tab_index=\(cachedTarget.tabIndex) attempt=\(attempt) success=\(focused ? "1" : "0") focus_ms=\(elapsedMS(since: focusByIndexStartedAt))"
            )

            if focused {
                let verifyStartedAt = currentDate()
                let activeURL = try chrome.frontmostActiveTabURL()
                let matchesWorkspace = {
                    guard let activeURL else { return false }
                    return browserURLMatchesWorkspace(activeURL, browserPrefixes: cachedTarget.browserPrefixes)
                }()
                logBrowserFocus(
                    "workspace=\(workspaceID) indexed_verify window=\(windowID) tab_index=\(cachedTarget.tabIndex) attempt=\(attempt) matches=\(matchesWorkspace ? "1" : "0") verify_ms=\(elapsedMS(since: verifyStartedAt)) url=\(activeURL ?? "")"
                )
                if matchesWorkspace {
                    logBrowserFocus(
                        "workspace=\(workspaceID) indexed_done window=\(windowID) target=\(targetURL) refreshed=\(refreshed ? "1" : "0") elapsed_ms=\(elapsedMS(since: focusStartedAt))"
                    )
                    return true
                }
            }
            guard attempt == 1 else { break }
            guard try refreshCachedBrowserWindows(workspaceID: workspaceID, browserPrefixes: cachedTarget.browserPrefixes) else { break }
            refreshed = true
        }
        logBrowserFocus(
            "workspace=\(workspaceID) indexed_failed window=\(windowID) target=\(targetURL) refreshed=\(refreshed ? "1" : "0") elapsed_ms=\(elapsedMS(since: focusStartedAt))"
        )
        return false
    }

    private func cachedScannedBrowserTabTarget(workspaceID: String, windowID: Int, targetURL: String) -> CachedScannedBrowserTabTarget? {
        browserScanCacheLock.lock()
        defer { browserScanCacheLock.unlock() }
        guard let entry = browserWindowScanCacheByWorkspace[workspaceID] else { return nil }
        let key = "\(windowID):\(targetURL)"
        guard let tabIndex = entry.scanResult.tabIndexByWindowAndURL[key] else { return nil }
        return CachedScannedBrowserTabTarget(tabIndex: tabIndex, browserPrefixes: entry.browserPrefixes)
    }

    private func refreshCachedBrowserWindows(workspaceID: String, browserPrefixes: [String]) throws -> Bool {
        guard !browserPrefixes.isEmpty else { return false }
        let refreshStartedAt = currentDate()
        _ = try liveBrowserWindows(workspaceID: workspaceID, browserPrefixes: browserPrefixes, forceRefresh: true)
        logBrowserFocus("workspace=\(workspaceID) indexed_refresh success=1 elapsed_ms=\(elapsedMS(since: refreshStartedAt))")
        return true
    }

    private func browserURLMatchesWorkspace(_ url: String, browserPrefixes: [String]) -> Bool {
        browserPrefixes.contains(where: { url.hasPrefix($0) })
    }

    private func elapsedMS(since startedAt: Date) -> Int { Int(currentDate().timeIntervalSince(startedAt) * 1000) }

    private func logBrowserFocus(_ message: String) {
        guard debugLoggingEnabled() else { return }
        fputs("spaceship: browser focus \(message)\n", stderr)
    }

    private func debugLoggingEnabled() -> Bool { ProcessInfo.processInfo.environment["DEBUG"] == "1" }

    private func scannedBrowserWindows(workspaceID: String, browserPrefixes: [String]) throws -> BrowserWindowScanResult {
        guard !browserPrefixes.isEmpty else { return BrowserWindowScanResult(windows: [], tabIndexByWindowAndURL: [:]) }
        let scanStartedAt = Date()
        let tabs = try chrome.allTabs()
        struct MatchedTab {
            let tab: ChromeWindowMatch
            let prefixIndex: Int
        }
        var matchedTabs: [MatchedTab] = []
        var seen = Set<String>()
        for tab in tabs {
            guard let prefixIndex = browserPrefixes.firstIndex(where: { tab.url.hasPrefix($0) }) else { continue }
            let key = "\(tab.windowID):\(tab.url)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            matchedTabs.append(MatchedTab(tab: tab, prefixIndex: prefixIndex))
        }
        matchedTabs.sort { lhs, rhs in
            if lhs.prefixIndex != rhs.prefixIndex { return lhs.prefixIndex < rhs.prefixIndex }
            if lhs.tab.url != rhs.tab.url { return lhs.tab.url < rhs.tab.url }
            if lhs.tab.windowID != rhs.tab.windowID { return lhs.tab.windowID < rhs.tab.windowID }
            return lhs.tab.title < rhs.tab.title
        }
        var browserWindows: [WindowRecord] = []
        var tabIndexByWindowAndURL: [String: Int] = [:]
        for (index, match) in matchedTabs.enumerated() {
            tabIndexByWindowAndURL["\(match.tab.windowID):\(match.tab.url)"] = match.tab.tabIndex
            browserWindows.append(
                WindowRecord(
                    id: UUID().uuidString, workspaceID: workspaceID, app: "Google Chrome", title: match.tab.title, targetURL: match.tab.url,
                    windowID: match.tab.windowID, role: "browser", orderIndex: index, lastSeenAt: nowISO8601()))
        }
        if debugLoggingEnabled() {
            let elapsedMS = Int(Date().timeIntervalSince(scanStartedAt) * 1000)
            fputs(
                "spaceship: browser scan workspace=\(workspaceID) tabs=\(tabs.count) matches=\(browserWindows.count) elapsed_ms=\(elapsedMS)\n",
                stderr)
        }
        return BrowserWindowScanResult(windows: browserWindows, tabIndexByWindowAndURL: tabIndexByWindowAndURL)
    }

    private func normalizedBrowserWindowRows(_ windows: [WindowRecord]) -> [WindowRecord] {
        let browserWindowIDsWithTarget = Set(
            windows.compactMap { window -> Int? in
                guard window.role == "browser", let windowID = window.windowID, window.targetURL != nil else { return nil }
                return windowID
            })
        return windows.filter { window in
            guard window.role == "browser", window.targetURL == nil, let windowID = window.windowID else { return true }
            return !browserWindowIDsWithTarget.contains(windowID)
        }
    }

    public func listSpaceOptions() throws -> [SpaceOption] {
        let spaces = try yabai.listSpaces()
        return spaces.map { SpaceOption(displayIndex: $0.display, spaceIndex: $0.index) }.sorted { lhs, rhs in
            if lhs.displayIndex == rhs.displayIndex { return lhs.spaceIndex < rhs.spaceIndex }
            return lhs.displayIndex < rhs.displayIndex
        }
    }

    public func guiHotkey() throws -> String { try store.setting(key: SettingsKey.guiHotkey) ?? SettingsKey.defaultGUIHotkey }

    public func setGUIHotkey(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiHotkey, value: raw) }

    public func guiNextShortcut() throws -> String { try store.setting(key: SettingsKey.guiNextShortcut) ?? SettingsKey.defaultGUINextShortcut }

    public func setGUINextShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiNextShortcut, value: raw) }

    public func guiPreviousShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiPreviousShortcut) ?? SettingsKey.defaultGUIPreviousShortcut
    }

    public func setGUIPreviousShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiPreviousShortcut, value: raw) }

    public func guiShowShortcut() throws -> String { try store.setting(key: SettingsKey.guiShowShortcut) ?? SettingsKey.defaultGUIShowShortcut }

    public func setGUIShowShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiShowShortcut, value: raw) }

    public func guiAddProjectShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiAddProjectShortcut) ?? SettingsKey.defaultGUIAddProjectShortcut
    }

    public func setGUIAddProjectShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiAddProjectShortcut, value: raw) }

    public func guiAddWorkspaceShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiAddWorkspaceShortcut) ?? SettingsKey.defaultGUIAddWorkspaceShortcut
    }

    public func setGUIAddWorkspaceShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiAddWorkspaceShortcut, value: raw) }

    public func guiReloadShortcut() throws -> String { try store.setting(key: SettingsKey.guiReloadShortcut) ?? SettingsKey.defaultGUIReloadShortcut }

    public func setGUIReloadShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiReloadShortcut, value: raw) }

    public func guiOpenEditorShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiOpenEditorShortcut) ?? SettingsKey.defaultGUIOpenEditorShortcut
    }

    public func setGUIOpenEditorShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiOpenEditorShortcut, value: raw) }

    public func guiOpenTerminalShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiOpenTerminalShortcut) ?? SettingsKey.defaultGUIOpenTerminalShortcut
    }

    public func setGUIOpenTerminalShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiOpenTerminalShortcut, value: raw) }

    public func guiOpenFinderShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiOpenFinderShortcut) ?? SettingsKey.defaultGUIOpenFinderShortcut
    }

    public func setGUIOpenFinderShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiOpenFinderShortcut, value: raw) }

    public func guiOpenSettingsShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiOpenSettingsShortcut) ?? SettingsKey.defaultGUIOpenSettingsShortcut
    }

    public func setGUIOpenSettingsShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiOpenSettingsShortcut, value: raw) }

    public func activeWorkspaceID() throws -> String? { try store.setting(key: "active_workspace_id") }

    public func setActiveWorkspace(id: String?) throws { try store.setSetting(key: "active_workspace_id", value: id) }

    private func normalize(project: ProjectConfig) throws -> NormalizedProject {
        let dir = normalizePath(project.dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw SpaceshipError.invalidArgument(message: "Project directory not found: \(dir)")
        }
        let isGit = git.isRepo(path: dir)
        let branch = isGit ? git.defaultBranch(path: dir) : nil
        let id = dir
        let name = URL(fileURLWithPath: dir).lastPathComponent
        var updatedConfig = project
        updatedConfig.dir = dir
        return NormalizedProject(
            id: id, record: ProjectRecord(id: id, name: name, dir: dir, isGitRepo: isGit, defaultBranch: branch), config: updatedConfig)
    }

    private func ensureDefaultWorkspace(for project: ProjectRecord) throws {
        if let existing = try store.workspace(projectID: project.id, name: "default") {
            if existing.isArchived {
                let revived = WorkspaceRecord(
                    id: existing.id, projectID: project.id, name: existing.name, dir: existing.dir, dirname: existing.dirname,
                    branch: existing.branch, isDefault: true, isArchived: false, isRunning: existing.isRunning,
                    lastLaunchedAt: existing.lastLaunchedAt)
                try store.upsert(workspace: revived)
            }
            return
        }
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, name: "default", dir: project.dir, dirname: nil, branch: project.defaultBranch,
            isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        try seedWorkspaceSettings(project: project, workspace: workspace)
        let appConfig = try configStore.load()
        let portDefinitions = try store.workspacePortDefinitions(workspaceID: workspace.id)
        _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, definitions: portDefinitions, range: appConfig.portRange)
    }

    private func resolveWorkspace(id: String) throws -> (ProjectRecord, WorkspaceRecord) {
        guard let workspace = try store.workspace(id: id) else { throw SpaceshipError.invalidArgument(message: "Workspace not found.") }
        guard let project = try store.project(id: workspace.projectID) else { throw SpaceshipError.missingProject(dir: workspace.projectID) }
        return (project, workspace)
    }

    private func ensureWorkspaceSettings(for project: ProjectRecord, config: ProjectConfig) throws {
        let workspaces = try store.workspaces(projectID: project.id, includeArchived: true)
        for workspace in workspaces {
            let hasSettings = try store.workspaceSettingsExists(workspaceID: workspace.id)
            if !hasSettings { try seedWorkspaceSettings(project: project, workspace: workspace, config: config) }
        }
    }

    private func syncDefaultWorkspaceSettingsIfTemplateBased(project: ProjectRecord, previousConfig: ProjectConfig, updatedConfig: ProjectConfig)
        throws
    {
        guard let defaultWorkspace = try store.workspace(projectID: project.id, name: "default") else { return }

        let hasSettings = try store.workspaceSettingsExists(workspaceID: defaultWorkspace.id)
        if !hasSettings {
            try seedWorkspaceSettings(project: project, workspace: defaultWorkspace, config: updatedConfig)
            return
        }

        let currentSettings = WorkspaceSettings(
            stopScript: try store.workspaceStopScript(workspaceID: defaultWorkspace.id),
            ports: try store.workspacePortDefinitions(workspaceID: defaultWorkspace.id),
            processes: try store.workspaceProcesses(workspaceID: defaultWorkspace.id),
            statusChecks: try store.workspaceStatusChecks(workspaceID: defaultWorkspace.id),
            browserSessions: try store.workspaceBrowserSessions(workspaceID: defaultWorkspace.id))

        let previousTemplate = WorkspaceSettings(
            stopScript: previousConfig.stopScript, ports: previousConfig.ports, processes: previousConfig.processes,
            statusChecks: previousConfig.statusChecks, browserSessions: previousConfig.browserSessions)

        guard workspaceSettingsMatch(currentSettings, previousTemplate) else { return }

        try seedWorkspaceSettings(project: project, workspace: defaultWorkspace, config: updatedConfig)
    }

    private func workspaceSettingsMatch(_ lhs: WorkspaceSettings, _ rhs: WorkspaceSettings) -> Bool {
        guard lhs.stopScript == rhs.stopScript else { return false }
        guard lhs.ports == rhs.ports else { return false }
        guard processTemplatesMatch(lhs.processes, rhs.processes) else { return false }
        guard statusChecksMatch(lhs.statusChecks, rhs.statusChecks) else { return false }
        guard browserSessionsMatch(lhs.browserSessions, rhs.browserSessions) else { return false }
        return true
    }

    private func processTemplatesMatch(_ lhs: [ProcessTemplate], _ rhs: [ProcessTemplate]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) { if left.name != right.name || left.command != right.command || left.kind != right.kind { return false } }
        return true
    }

    private func statusChecksMatch(_ lhs: [StatusCheckDefinition], _ rhs: [StatusCheckDefinition]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            if left.name != right.name || left.process != right.process || left.command != right.command || left.interval != right.interval
                || left.timeout != right.timeout || left.onExit != right.onExit
            {
                return false
            }
        }
        return true
    }

    private func browserSessionsMatch(_ lhs: [BrowserSession], _ rhs: [BrowserSession]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) where left.url != right.url { return false }
        return true
    }

    private func seedWorkspaceSettings(project: ProjectRecord, workspace: WorkspaceRecord) throws {
        let config = try projectConfig(projectID: project.id)
        try seedWorkspaceSettings(project: project, workspace: workspace, config: config)
    }

    private func seedWorkspaceSettings(project _: ProjectRecord, workspace: WorkspaceRecord, config: ProjectConfig?) throws {
        let snapshot = WorkspaceSettings(
            stopScript: config?.stopScript, ports: config?.ports ?? [], processes: config?.processes ?? [],
            statusChecks: config?.statusChecks ?? [], browserSessions: config?.browserSessions ?? [])
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: snapshot.stopScript)
        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: snapshot.ports)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: snapshot.processes)
        try store.setWorkspaceStatusChecks(workspaceID: workspace.id, checks: snapshot.statusChecks)
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: snapshot.browserSessions)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: nowISO8601())
    }

    private func loadWorkspaceSettings(project: ProjectRecord, workspace: WorkspaceRecord, config: ProjectConfig?) throws -> WorkspaceSettings? {
        let hasSettings = try store.workspaceSettingsExists(workspaceID: workspace.id)
        if !hasSettings { try seedWorkspaceSettings(project: project, workspace: workspace, config: config) }
        let stopScript = try store.workspaceStopScript(workspaceID: workspace.id)
        let ports = try store.workspacePortDefinitions(workspaceID: workspace.id)
        let processes = try store.workspaceProcesses(workspaceID: workspace.id)
        let statusChecks = try store.workspaceStatusChecks(workspaceID: workspace.id)
        let browserSessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        return WorkspaceSettings(
            stopScript: stopScript, ports: ports, processes: processes, statusChecks: statusChecks, browserSessions: browserSessions)
    }

    private func runScript(_ script: String, cwd: String) throws { _ = try Shell.run(["/bin/bash", "-lc", script], cwd: cwd) }

    private func buildWorkspaceEnv(project: ProjectRecord, workspace: WorkspaceRecord, namedPorts: [(port: Int, name: String)]) -> [String: String] {
        var env: [String: String] = [:]
        for namedPort in namedPorts {
            let key = namedPort.name.isEmpty ? "PORT\(env.count)" : namedPort.name
            env[key] = String(namedPort.port)
        }
        env["spaceship_WORKSPACE_DIR"] = workspace.dir
        let scopedKey = "spaceship_\(sanitizeEnvKey(project.name))_\(sanitizeEnvKey(workspace.name))_WORKSPACE_DIR"
        env[scopedKey] = workspace.dir
        return env
    }

    private func applyWorkspaceSettingsUpdate(
        project: ProjectRecord, workspace: WorkspaceRecord, previous: WorkspaceSettings, updated: WorkspaceSettings
    ) throws {
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        try reconcileProcesses(workspace: workspace, previous: previous.processes, updated: updated.processes, env: env)
        try reconcileBrowserSessions(project: project, workspace: workspace, sessions: updated.browserSessions, env: env)
        try pruneMissingWindows(workspaceID: workspace.id)
    }

    private func processKey(for template: ProcessTemplate) -> String {
        let name = template.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = template.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? command : name
    }

    private func processRuntimePaths(workspaceID: String, name: String) throws -> (logFile: String, pidFile: String) {
        let runtimeRoot = try runtimeDirectory()
        let workspaceRuntime = URL(fileURLWithPath: runtimeRoot).appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRuntime, withIntermediateDirectories: true)
        let safe = safeFilename(name)
        let logFile = workspaceRuntime.appendingPathComponent("\(safe).log").path
        let pidFile = workspaceRuntime.appendingPathComponent("\(safe).pid").path
        return (logFile, pidFile)
    }

    private func reconcileProcesses(workspace: WorkspaceRecord, previous: [ProcessTemplate], updated: [ProcessTemplate], env: [String: String]) throws
    {
        struct DesiredProcess {
            let matchKey: String
            let desiredKey: String
            let template: ProcessTemplate
        }

        let running = try store.runningProcesses(workspaceID: workspace.id)
        let runningByKey = Dictionary(uniqueKeysWithValues: running.map { ($0.templateName, $0) })

        var desiredByMatch: [String: DesiredProcess] = [:]
        for (idx, template) in updated.enumerated() {
            let desiredKey = processKey(for: template)
            let hasName = !(template.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            var matchKey = desiredKey
            if !hasName, idx < previous.count {
                let previousKey = processKey(for: previous[idx])
                if desiredKey == template.command && !previousKey.isEmpty { matchKey = previousKey }
            }
            if desiredByMatch[matchKey] == nil {
                desiredByMatch[matchKey] = DesiredProcess(matchKey: matchKey, desiredKey: desiredKey, template: template)
            }
        }

        let toStop = running.filter { desiredByMatch[$0.templateName] == nil }
        let toStart = desiredByMatch.filter { runningByKey[$0.key] == nil }
        var toRestart: [(DesiredProcess, RunningProcessRecord)] = []
        var toRelabel: [(DesiredProcess, RunningProcessRecord)] = []
        for desired in desiredByMatch.values {
            if let running = runningByKey[desired.matchKey] {
                if running.command != desired.template.command {
                    toRestart.append((desired, running))
                } else if running.templateName != desired.desiredKey {
                    toRelabel.append((desired, running))
                }
            }
        }

        if !toStart.isEmpty || !toRestart.isEmpty, !iterm.isAvailable() {
            throw SpaceshipError.dependencyMissing(message: "iTerm2 is required to launch processes.")
        }

        for process in toStop {
            if let pid = resolvedRuntimePID(for: process) { terminateProcessGroup(pid: pid) }
            if let windowID = process.windowID, process.terminalApp == "iTerm2" { _ = try? iterm.closeWindow(id: windowID) }
            try store.deleteRunningProcess(id: process.id)
        }

        for (desired, process) in toRelabel {
            let updated = RunningProcessRecord(
                id: process.id, workspaceID: workspace.id, templateName: desired.desiredKey, command: process.command,
                terminalApp: process.terminalApp, windowID: process.windowID, pid: process.pid, status: process.status, logPath: process.logPath,
                lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: process.exitedAt)
            try store.upsert(runningProcess: updated)
        }

        var existingWindowIDs = Set<Int>((try store.windows(workspaceID: workspace.id)).compactMap { $0.windowID })
        var terminalCount = (try? store.windows(workspaceID: workspace.id).filter { $0.role == "terminal" }.count) ?? 0

        for (desired, process) in toRestart {
            let name = desired.desiredKey
            let (logFile, pidFile) = try processRuntimePaths(workspaceID: workspace.id, name: name)
            let command = shellCommand(base: desired.template.command, cwd: workspace.dir, env: env, logFile: logFile, pidFile: pidFile)
            if let windowID = process.windowID {
                if let pid = resolvedRuntimePID(for: process) { terminateProcessGroup(pid: pid) }
                try iterm.runInWindow(id: windowID, command: command)
                let pid = try? Int(String(contentsOfFile: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))
                let updated = RunningProcessRecord(
                    id: process.id, workspaceID: workspace.id, templateName: desired.desiredKey, command: desired.template.command,
                    terminalApp: "iTerm2", windowID: windowID, pid: pid, status: .running, logPath: logFile, lastOutputAt: nil,
                    startedAt: nowISO8601(), exitedAt: nil)
                try store.upsert(runningProcess: updated)
            } else {
                let snapshot = try yabai.listWindows()
                let window = try iterm.openWindowAndRun(command: command)
                let captured = try captureNewWindows(
                    snapshot: snapshot, role: "terminal", appName: "iTerm2", workspaceID: workspace.id, orderOffset: 200 + terminalCount)
                let resolvedWindowID = window.id >= 0 ? window.id : captured.first?.windowID
                let pid = try? Int(String(contentsOfFile: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))
                let updated = RunningProcessRecord(
                    id: process.id, workspaceID: workspace.id, templateName: desired.desiredKey, command: desired.template.command,
                    terminalApp: "iTerm2", windowID: resolvedWindowID, pid: pid, status: .running, logPath: logFile, lastOutputAt: nil,
                    startedAt: nowISO8601(), exitedAt: nil)
                try store.upsert(runningProcess: updated)
                try upsertCapturedTerminalWindows(captured, existingWindowIDs: &existingWindowIDs, terminalCount: &terminalCount)
            }
        }

        for (_, desired) in toStart {
            let name = desired.desiredKey
            let (logFile, pidFile) = try processRuntimePaths(workspaceID: workspace.id, name: name)
            let command = shellCommand(base: desired.template.command, cwd: workspace.dir, env: env, logFile: logFile, pidFile: pidFile)
            let snapshot = try yabai.listWindows()
            let window = try iterm.openWindowAndRun(command: command)
            let captured = try captureNewWindows(
                snapshot: snapshot, role: "terminal", appName: "iTerm2", workspaceID: workspace.id, orderOffset: 200 + terminalCount)
            let resolvedWindowID = window.id >= 0 ? window.id : captured.first?.windowID
            let pid = try? Int(String(contentsOfFile: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))
            let record = RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: desired.desiredKey, command: desired.template.command,
                terminalApp: "iTerm2", windowID: resolvedWindowID, pid: pid, status: .running, logPath: logFile, lastOutputAt: nil,
                startedAt: nowISO8601(), exitedAt: nil)
            try store.upsert(runningProcess: record)
            try upsertCapturedTerminalWindows(captured, existingWindowIDs: &existingWindowIDs, terminalCount: &terminalCount)
        }

        let ensuredTerminals = try terminalWindowsFromRunningProcesses(
            workspace: workspace, existingWindows: try store.windows(workspaceID: workspace.id))
        for window in ensuredTerminals { try store.upsert(window: window) }
    }

    private func reconcileBrowserSessions(project: ProjectRecord, workspace: WorkspaceRecord, sessions: [BrowserSession], env: [String: String])
        throws
    {
        let tracked = try store.windows(workspaceID: workspace.id).filter { $0.role == "browser" }
        if sessions.isEmpty {
            for window in tracked {
                closeTrackedBrowserTab(window)
                try store.deleteWindow(id: window.id)
            }
            return
        }
        guard chrome.isAvailable() else { throw SpaceshipError.dependencyMissing(message: "Google Chrome is required for browser sessions.") }
        let snapshot = try yabai.listWindows()
        let browserSessionResult = try ensureBrowserSessions(
            project: project, workspace: workspace, sessions: sessions, env: env, extractOnAttach: false)
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: browserSessionResult.sessions)
        let attached = browserSessionResult.windows
        let attachedIDs = Set(attached.compactMap { $0.windowID })
        let capturedRaw = try captureNewWindows(
            snapshot: snapshot, role: "browser", appName: "Google Chrome", workspaceID: workspace.id, orderOffset: 0)
        let captured = capturedRaw.filter { window in
            guard let id = window.windowID else { return true }
            return !attachedIDs.contains(id)
        }
        let desiredWindows = attached + captured
        let desiredIDs = attachedIDs.union(captured.compactMap { $0.windowID })
        let desiredKeys = Set(desiredWindows.map(windowTrackingKey))
        for window in tracked {
            guard let id = window.windowID else {
                try store.deleteWindow(id: window.id)
                continue
            }
            let key = windowTrackingKey(window)
            if !desiredKeys.contains(key) {
                if !desiredIDs.contains(id) { closeTrackedBrowserTab(window) }
                try store.deleteWindow(id: window.id)
            }
        }
        var existingKeys = Set<String>()
        for window in desiredWindows {
            let key = windowTrackingKey(window)
            if existingKeys.contains(key) { continue }
            existingKeys.insert(key)
            try store.upsert(window: window)
        }
    }

    private func pruneMissingWindows(workspaceID: String) throws {
        let existingIDs = Set(try yabai.listWindows().map(\.id))
        let windows = try store.windows(workspaceID: workspaceID)
        for window in windows {
            guard let id = window.windowID else {
                try store.deleteWindow(id: window.id)
                continue
            }
            if !existingIDs.contains(id) { try store.deleteWindow(id: window.id) }
        }
    }

    private func windowTrackingKey(_ window: WindowRecord) -> String {
        let idPart = window.windowID.map(String.init) ?? "none"
        if window.role == "browser" { return "browser:\(idPart):\(window.targetURL ?? "")" }
        return "\(window.role):\(idPart)"
    }

    private func closeTrackedBrowserTab(_ window: WindowRecord) {
        guard window.role == "browser", let targetURL = window.targetURL, chrome.isAvailable() else { return }
        if let trackedWindowID = window.windowID {
            let closedTrackedWindowTabs = (try? chrome.closeTabs(forURLPrefix: targetURL, windowID: trackedWindowID)) ?? false
            if closedTrackedWindowTabs { return }
        }
        _ = try? chrome.closeTabs(forURLPrefix: targetURL)
    }

    private func upsertCapturedTerminalWindows(_ captured: [WindowRecord], existingWindowIDs: inout Set<Int>, terminalCount: inout Int) throws {
        for windowRecord in captured {
            guard let id = windowRecord.windowID, !existingWindowIDs.contains(id) else { continue }
            existingWindowIDs.insert(id)
            terminalCount += 1
            try store.upsert(window: windowRecord)
        }
    }

    private func terminalWindowsFromRunningProcesses(workspace: WorkspaceRecord, existingWindows: [WindowRecord]) throws -> [WindowRecord] {
        let processRecords = try store.runningProcesses(workspaceID: workspace.id)
        let terminalProcessWindowIDs = processRecords.filter { $0.terminalApp == "iTerm2" }.compactMap(\.windowID)
        guard !terminalProcessWindowIDs.isEmpty else { return [] }
        let yabaiWindowsByID = Dictionary(uniqueKeysWithValues: try yabai.listWindows().map { ($0.id, $0) })
        var seenWindowIDs = Set(existingWindows.compactMap(\.windowID))
        var nextIndex = Self.nextWindowOrderIndex(existing: existingWindows, role: "terminal", orderOffset: 200)
        var synthesized: [WindowRecord] = []
        for windowID in terminalProcessWindowIDs {
            if seenWindowIDs.contains(windowID) { continue }
            guard let yabaiWindow = yabaiWindowsByID[windowID] else { continue }
            seenWindowIDs.insert(windowID)
            synthesized.append(
                WindowRecord(
                    id: UUID().uuidString, workspaceID: workspace.id, app: yabaiWindow.app, title: yabaiWindow.title, windowID: windowID,
                    role: "terminal", orderIndex: nextIndex, lastSeenAt: nowISO8601()))
            nextIndex += 1
        }
        return synthesized
    }

    static func nextWindowOrderIndex(existing: [WindowRecord], role: String, orderOffset: Int) -> Int {
        let maxIndex = existing.filter { $0.role == role }.map(\.orderIndex).max() ?? (orderOffset - 1)
        return max(maxIndex + 1, orderOffset)
    }

    private func attachNewWindows(snapshot: [YabaiWindow], workspaceID: String, role: String, appName: String, orderOffset: Int) throws {
        try attachNewWindows(snapshot: snapshot, workspaceID: workspaceID, role: role, appNames: [appName], orderOffset: orderOffset)
    }

    private func attachNewWindows(snapshot: [YabaiWindow], workspaceID: String, role: String, appNames: Set<String>, orderOffset: Int) throws {
        var captured = try captureNewWindows(snapshot: snapshot, role: role, appNames: appNames, workspaceID: workspaceID, orderOffset: orderOffset)
        if captured.isEmpty, let focused = try yabai.focusedWindow(), appNames.contains(focused.app) {
            captured = [
                WindowRecord(
                    id: UUID().uuidString, workspaceID: workspaceID, app: focused.app, title: focused.title, windowID: focused.id, role: role,
                    orderIndex: orderOffset, lastSeenAt: nowISO8601())
            ]
        }
        guard !captured.isEmpty else { return }
        let existing = try store.windows(workspaceID: workspaceID)
        var existingIDs = Set(existing.compactMap(\.windowID))
        var nextIndex = Self.nextWindowOrderIndex(existing: existing, role: role, orderOffset: orderOffset)
        for window in captured {
            guard let id = window.windowID else { continue }
            if existingIDs.contains(id) { continue }
            existingIDs.insert(id)
            let stored = WindowRecord(
                id: window.id, workspaceID: workspaceID, app: window.app, title: window.title, windowID: id, role: role, orderIndex: nextIndex,
                lastSeenAt: nowISO8601())
            nextIndex += 1
            try store.upsert(window: stored)
        }
    }

    private func launchProcesses(workspace: WorkspaceRecord, templates: [ProcessTemplate], env: [String: String]) throws {
        guard !templates.isEmpty else {
            try store.deleteRunningProcesses(workspaceID: workspace.id)
            return
        }
        guard iterm.isAvailable() else { throw SpaceshipError.dependencyMissing(message: "iTerm2 is required to launch processes.") }
        let runtimeRoot = try runtimeDirectory()
        let workspaceRuntime = URL(fileURLWithPath: runtimeRoot).appendingPathComponent(workspace.id, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRuntime, withIntermediateDirectories: true)

        try store.deleteRunningProcesses(workspaceID: workspace.id)

        for template in templates {
            let name = template.name ?? template.command
            let logFile = workspaceRuntime.appendingPathComponent("\(safeFilename(name)).log").path
            let pidFile = workspaceRuntime.appendingPathComponent("\(safeFilename(name)).pid").path
            let command = shellCommand(base: template.command, cwd: workspace.dir, env: env, logFile: logFile, pidFile: pidFile)
            let snapshot = try yabai.listWindows()
            let window = try iterm.openWindowAndRun(command: command)
            let fallbackWindowID = try captureNewWindows(
                snapshot: snapshot, role: "terminal", appName: "iTerm2", workspaceID: workspace.id, orderOffset: 200
            ).first?.windowID

            let pid = try? Int(String(contentsOfFile: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))
            let running = RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: name, command: template.command, terminalApp: "iTerm2",
                windowID: window.id >= 0 ? window.id : fallbackWindowID, pid: pid, status: .running, logPath: logFile, lastOutputAt: nil,
                startedAt: nowISO8601(), exitedAt: nil)
            try store.upsert(runningProcess: running)
        }

    }

    private func ensureBrowserSessions(
        project: ProjectRecord, workspace: WorkspaceRecord, sessions: [BrowserSession], env: [String: String], extractOnAttach: Bool
    ) throws -> (windows: [WindowRecord], sessions: [BrowserSession])
    {
        _ = project
        guard !sessions.isEmpty else { return ([], []) }
        guard chrome.isAvailable() else { throw SpaceshipError.dependencyMissing(message: "Google Chrome is required for browser sessions.") }
        let resolvedSessions = resolveBrowserSessions(sessions, env: env)
        var attached: [WindowRecord] = []
        var refreshedSessions = sessions
        var seenKeys = Set<String>()
        for resolvedSession in resolvedSessions {
            var matches = try chrome.windowMatches(forURLPrefix: resolvedSession.prefix)
            if matches.isEmpty {
                _ = try chrome.openWindow(url: resolvedSession.prefix)
                matches = try chrome.windowMatches(forURLPrefix: resolvedSession.prefix)
            }
            if extractOnAttach,
                let extractedWindowID = try extractSessionWindowIfNeeded(
                    session: resolvedSession, matches: matches, refreshedSessions: &refreshedSessions)
            {
                let extractedMatches = try chrome.windowMatches(forURLPrefix: resolvedSession.prefix).filter { $0.windowID == extractedWindowID }
                if !extractedMatches.isEmpty {
                    matches = extractedMatches
                }
            }
            for match in matches {
                let key = "browser:\(match.windowID):\(match.url)"
                if seenKeys.contains(key) { continue }
                seenKeys.insert(key)
                attached.append(
                    WindowRecord(
                        id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: match.title, targetURL: match.url,
                        windowID: match.windowID, role: "browser", orderIndex: attached.count, lastSeenAt: nowISO8601()))
            }
            if !matches.isEmpty { continue }
            if (try? chrome.focusTab(forURLPrefix: resolvedSession.prefix)) ?? false, let focused = try? yabai.focusedWindow(), focused.app == "Google Chrome" {
                let key = "browser:\(focused.id):\(resolvedSession.prefix)"
                if seenKeys.contains(key) { continue }
                seenKeys.insert(key)
                attached.append(
                    WindowRecord(
                        id: UUID().uuidString, workspaceID: workspace.id, app: focused.app, title: focused.title,
                        targetURL: resolvedSession.prefix,
                        windowID: focused.id, role: "browser", orderIndex: attached.count, lastSeenAt: nowISO8601()))
            }
        }
        return (attached, refreshedSessions)
    }

    private func captureNewWindows(snapshot: [YabaiWindow], role: String, appName: String, workspaceID: String, orderOffset: Int) throws
        -> [WindowRecord]
    {
        try captureNewWindows(snapshot: snapshot, role: role, appNames: [appName], workspaceID: workspaceID, orderOffset: orderOffset)
    }

    private func captureNewWindows(snapshot: [YabaiWindow], role: String, appNames: Set<String>, workspaceID: String, orderOffset: Int) throws
        -> [WindowRecord]
    {
        let after = try yabai.listWindows()
        let snapshotIDs = Set(snapshot.map(\.id))
        let created = after.filter { !snapshotIDs.contains($0.id) && appNames.contains($0.app) }
        return created.enumerated().map { idx, win in
            WindowRecord(
                id: UUID().uuidString, workspaceID: workspaceID, app: win.app, title: win.title, windowID: win.id, role: role,
                orderIndex: orderOffset + idx, lastSeenAt: nowISO8601())
        }
    }

    private func runtimeDirectory() throws -> String {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["SPACESHIP_RUNTIME_DIR"], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            dir = home.appendingPathComponent(".spaceship", isDirectory: true).appendingPathComponent("runtime", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func shellCommand(base: String, cwd: String, env: [String: String], logFile: String, pidFile: String) -> String {
        let envExports = env.map { key, value in return "export \(key)=\"\(value)\"" }.sorted().joined(separator: "; ")
        let safeCwd = cwd
        let safeLog = logFile
        let safePid = pidFile
        let commands = [
            "cd \"\(safeCwd)\"", envExports.isEmpty ? nil : envExports, "echo $$ > \"\(safePid)\"", "\(base) 2>&1 | tee -a \"\(safeLog)\"",
        ].compactMap { $0 }
        let script = commands.joined(separator: "; ")
        let singleQuoted = script.replacing("'", with: "'\\''")
        return "bash -lc '\(singleQuoted)'"
    }

    private func applyEnvVars(_ input: String, env: [String: String]) -> String {
        var output = input
        for (key, value) in env { output = output.replacingOccurrences(of: "$\(key)", with: value) }
        return output
    }

    private func runCommandWithTimeout(command: String, cwd: String, timeout: Int, env: [String: String]) throws -> CommandOutcome {
        let process = Process()
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = out
        process.standardError = out

        var environment = currentProcessEnvironment()
        for (key, value) in env { environment[key] = value }
        process.environment = environment

        try process.run()

        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CommandOutcome(exitCode: process.terminationStatus, output: output)
    }

    private func currentProcessEnvironment() -> [String: String] {
        var environment: [String: String] = [:]
        var cursor = environ
        while let entry = cursor.pointee {
            let line = String(cString: entry)
            if let separator = line.firstIndex(of: "=") {
                let key = String(line[..<separator])
                let value = String(line[line.index(after: separator)...])
                environment[key] = value
            }
            cursor = cursor.advanced(by: 1)
        }
        return environment
    }

    private func terminateProcessGroup(pid: Int) {
        guard pid > 0 else { return }
        let groupTarget = processGroupID(for: pid) ?? pid
        let processGroupID = "-\(groupTarget)"
        // Send interrupt first so interactive commands like `docker compose up` shut down cleanly.
        _ = try? Shell.run(["kill", "-INT", "--", processGroupID])
        waitForProcessExit(pid: pid, timeout: 2.0)
        guard isProcessAlive(pid: pid) else { return }
        // Follow with TERM only if interrupt did not stop the process.
        _ = try? Shell.run(["kill", "-TERM", "--", processGroupID])
        waitForProcessExit(pid: pid, timeout: 2.0)
        guard isProcessAlive(pid: pid) else { return }
        // Fallback: target the tracked shell process directly.
        _ = try? Shell.run(["kill", "-TERM", "\(pid)"])
    }

    private func processGroupID(for pid: Int) -> Int? {
        guard pid > 0 else { return nil }
        guard let output = try? Shell.runAndCapture(["ps", "-o", "pgid=", "-p", "\(pid)"]) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let groupID = Int(trimmed), groupID > 0 else { return nil }
        return groupID
    }

    private func resolvedRuntimePID(for process: RunningProcessRecord) -> Int? {
        if let pid = process.pid, pid > 0 { return pid }
        guard process.terminalApp == "iTerm2" else { return nil }
        guard let pidFile = try? processRuntimePaths(workspaceID: process.workspaceID, name: process.templateName).pidFile else { return nil }
        return runtimePID(fromFile: pidFile)
    }

    private func runtimePID(fromFile path: String) -> Int? {
        guard let contents = try? String(contentsOfFile: path) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int(trimmed), pid > 0 else { return nil }
        return pid
    }

    private func isProcessAlive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    private func waitForProcessExit(pid: Int, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while isProcessAlive(pid: pid), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }

    private func nowISO8601() -> String { ISO8601DateFormatter().string(from: Date()) }

    private func normalizePath(_ path: String) -> String {
        let expanded = expandTilde(path)
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            let suffix = path.dropFirst(2)
            return URL(fileURLWithPath: home).appendingPathComponent(String(suffix)).path
        }
        return path
    }

    private static let workspaceFoodNames: [String] = [
        "almond", "anchovy", "apple", "apricot", "avocado", "bagel", "bacon", "banana", "basil", "bean", "beef", "beet", "berry", "biscuit", "bread",
        "broccoli", "brownie", "burger", "burrito", "butter", "cabbage", "cacao", "candy", "cantaloupe", "caramel", "carrot", "cashew", "celery",
        "cereal", "cherry", "cheddar", "cheesecake", "chili", "chips", "chive", "chocolate", "chutney", "cider", "cinnamon", "clove", "cocoa",
        "coconut", "coffee", "coleslaw", "cookie", "corn", "couscous", "cracker", "cream", "crouton", "cucumber", "cupcake", "curry", "custard",
        "danish", "dill", "donut", "dumpling", "eclair", "edamame", "egg", "empanada", "endive", "fajita", "falafel", "fig", "flan", "fries",
        "garlic", "ginger", "gnocchi", "granola", "grape", "gravy", "grits", "guava", "ham", "hazelnut", "honey", "hummus", "icecream", "jam",
        "jalapeno", "jelly", "kale", "kebab", "ketchup", "kiwi", "kohlrabi", "lasagna", "leek", "lemon", "lentil", "lettuce", "lime", "lobster",
        "lychee", "macaroni", "macaron", "mango", "maple", "marshmallow", "mascarpone", "mayo", "meatball", "melon", "mint", "mocha", "molasses",
        "muffin", "mushroom", "mustard", "nacho", "noodle", "nutmeg", "oat", "omelet", "olive", "onion", "orange", "oreo", "pancake", "papaya",
        "paprika", "parsnip", "pastry", "peach", "peanut", "pear", "peas", "pecan", "pepper", "pesto", "pho", "pickle", "pie", "pineapple", "pita",
        "pizza", "plum", "poppy", "popcorn", "pork", "potato", "poutine", "pretzel", "prune", "pudding", "pumpkin", "quiche", "quinoa", "radish",
        "raisin", "ramen", "relish", "rice", "risotto", "roast", "roll", "saffron", "sage", "salad", "salami", "salsa", "salt", "sardine", "sausage",
        "scone", "seaweed", "sesame", "shallot", "shrimp", "soup", "sorbet", "soy", "spice", "spinach", "squash", "steak", "stew", "sugar", "sushi",
        "syrup", "taco", "tamarind", "tapioca", "tea", "toffee", "toast", "tofu", "tomato", "tortilla", "tuna", "turkey", "turnip", "vanilla",
        "vinegar", "waffle", "walnut", "watermelon", "yams", "yogurt", "ziti", "zucchini",
    ]

    private func worktreeRoot(project: ProjectRecord) throws -> URL {
        let projectDirname = sanitizeDirname(project.name, fallback: "project")
        return workspaceRootDirectory().appending(path: projectDirname, directoryHint: .isDirectory)
    }

    private func makeWorkspaceDirname(project: ProjectRecord, existingDirname: String?, requestedDirname: String?) throws -> String {
        if let requestedDirname, !requestedDirname.isEmpty {
            try validateWorkspaceDirname(requestedDirname)
            let used = try usedWorkspaceDirnames(project: project, excludingDirname: existingDirname)
            guard !used.contains(requestedDirname) else {
                throw SpaceshipError.invalidArgument(message: "Workspace directory name is already in use: \(requestedDirname)")
            }
            return requestedDirname
        }
        if let existingDirname, !existingDirname.isEmpty { return existingDirname }
        let used = try usedWorkspaceDirnames(project: project, excludingDirname: nil)
        if let available = SpaceshipOrchestrator.workspaceFoodNames.first(where: { !used.contains($0) }) { return available }
        throw SpaceshipError.invalidArgument(message: "No available workspace dirnames remain for project \(project.name).")
    }

    private func usedWorkspaceDirnames(project: ProjectRecord, excludingDirname: String?) throws -> Set<String> {
        let records = try store.workspaces(projectID: project.id, includeArchived: true)
        var used = Set<String>()
        for record in records { if let dirname = record.dirname, !dirname.isEmpty, dirname != excludingDirname { used.insert(dirname) } }
        let root = try worktreeRoot(project: project)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for entry in entries where entry != excludingDirname { used.insert(entry) }
        }
        return used
    }

    private func validateWorkspaceDirname(_ dirname: String) throws {
        guard !dirname.isEmpty else { throw SpaceshipError.invalidArgument(message: "Workspace directory name cannot be empty.") }
        if dirname.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            throw SpaceshipError.invalidArgument(message: "Workspace directory name cannot contain spaces.")
        }
        for scalar in dirname.unicodeScalars {
            guard scalar.isASCII else {
                throw SpaceshipError.invalidArgument(message: "Workspace directory name can only use letters, numbers, '-', and '_'.")
            }
            let value = scalar.value
            let isUppercaseLetter = value >= 65 && value <= 90
            let isLowercaseLetter = value >= 97 && value <= 122
            let isDigit = value >= 48 && value <= 57
            let isHyphen = value == 45
            let isUnderscore = value == 95
            guard isUppercaseLetter || isLowercaseLetter || isDigit || isHyphen || isUnderscore else {
                throw SpaceshipError.invalidArgument(message: "Workspace directory name can only use letters, numbers, '-', and '_'.")
            }
        }
    }

    private func isMissingWorktreeError(_ error: Error) -> Bool {
        guard case SpaceshipError.gitCommandFailed(let message) = error else { return false }
        let lowered = message.lowercased()
        return lowered.contains("not a working tree") || lowered.contains("does not exist") || lowered.contains("no such file or directory")
    }

    private func sanitizeDirname(_ raw: String, fallback: String) -> String {
        let cleaned = raw.map { char -> String in
            if char.isLetter || char.isNumber { return String(char) }
            if char == "-" || char == "_" { return String(char) }
            return "-"
        }.joined()
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func projectsRootDirectory() -> URL {
        if let projectsRootDirectoryURL { return projectsRootDirectoryURL }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "spaceship", directoryHint: .isDirectory).appending(path: "projects", directoryHint: .isDirectory)
    }

    private func workspaceRootDirectory() -> URL {
        if let workspacesRootDirectoryURL { return workspacesRootDirectoryURL }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "spaceship", directoryHint: .isDirectory).appending(path: "workspaces", directoryHint: .isDirectory)
    }

    private func removeManagedGitWorkspaceDirectoriesIfNeeded(project: ProjectRecord) throws {
        guard project.isGitRepo else { return }
        let root = try worktreeRoot(project: project)
        let normalizedRoot = normalizePath(root.path)
        guard isManagedWorkspacesDirectory(path: normalizedRoot, allowEqual: true) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedRoot, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        try FileManager.default.removeItem(atPath: normalizedRoot)
    }

    private func removeManagedGitWorktreesIfNeeded(project: ProjectRecord, workspaces: [WorkspaceRecord]) throws {
        guard project.isGitRepo else { return }
        var processedPaths = Set<String>()
        for workspace in workspaces {
            let normalizedWorkspacePath = normalizePath(workspace.dir)
            guard normalizedWorkspacePath != project.dir else { continue }
            guard isManagedWorkspacesDirectory(path: normalizedWorkspacePath) else { continue }
            guard !processedPaths.contains(normalizedWorkspacePath) else { continue }
            processedPaths.insert(normalizedWorkspacePath)
            do { try git.removeWorktree(path: project.dir, worktreePath: workspace.dir) } catch { if !isMissingWorktreeError(error) { throw error } }
        }
    }

    private func removeManagedProjectDirectoryIfNeeded(project: ProjectRecord) throws {
        guard project.isGitRepo, isManagedProjectsDirectory(path: project.dir) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.dir, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        try FileManager.default.removeItem(atPath: project.dir)
    }

    private func isManagedProjectsDirectory(path: String) -> Bool { isPath(path, inside: projectsRootDirectory().path) }

    private func isManagedWorkspacesDirectory(path: String, allowEqual: Bool = false) -> Bool {
        isPath(path, inside: workspaceRootDirectory().path, allowEqual: allowEqual)
    }

    private func isPath(_ path: String, inside rootPath: String, allowEqual: Bool = false) -> Bool {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        if allowEqual {
            guard candidateComponents.count >= rootComponents.count else { return false }
        } else {
            guard candidateComponents.count > rootComponents.count else { return false }
        }
        return candidateComponents.starts(with: rootComponents)
    }

    private func inferredProjectName(from gitURL: String) -> String {
        var raw = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        if !raw.contains("://"), let colon = raw.lastIndex(of: ":"), let slash = raw.lastIndex(of: "/"), colon > slash {
            raw = String(raw[raw.index(after: colon)...])
        }
        let lastSegment = raw.split(separator: "/").last.map(String.init) ?? raw
        if lastSegment.hasSuffix(".git") { return String(lastSegment.dropLast(4)) }
        return lastSegment
    }

    private func sanitizeEnvKey(_ raw: String) -> String {
        raw.uppercased().map { char in
            if char.isLetter || char.isNumber { return char }
            return "_"
        }.reduce("") { $0 + String($1) }
    }

    private func safeFilename(_ raw: String) -> String {
        raw.map { char in
            if char.isLetter || char.isNumber { return char }
            return "_"
        }.reduce("") { $0 + String($1) }
    }

    private func editorAppName(_ editor: EditorPreference) -> String {
        switch editor {
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .vim: return "Terminal"
        case .none: return "Terminal"
        }
    }

    private func editorAppNames(_ editor: EditorPreference) -> Set<String> {
        switch editor {
        case .vscode: return ["Visual Studio Code", "Code"]
        case .cursor: return ["Cursor"]
        case .windsurf: return ["Windsurf"]
        case .vim: return ["Terminal"]
        case .none: return ["Terminal"]
        }
    }
}
