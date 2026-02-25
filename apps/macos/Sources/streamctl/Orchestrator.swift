import Darwin
import Foundation
@preconcurrency import UserNotifications
import appctl

public final class MuxyOrchestrator {
    public struct WorkspaceStopOutcome: Sendable {
        public let skippedStopScriptBecauseWorkspaceDirectoryMissing: Bool

        public init(skippedStopScriptBecauseWorkspaceDirectoryMissing: Bool) {
            self.skippedStopScriptBecauseWorkspaceDirectoryMissing = skippedStopScriptBecauseWorkspaceDirectoryMissing
        }
    }

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

    private struct ItermTerminalSessionMetadata {
        let sessionID: String
        let tabIndex: Int?
    }

    public let store: SQLiteStore
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
    private let workspaceSetupLock = NSLock()
    private var workspaceSetupInFlight: Set<String> = []
    private let windowNavigationLock = NSLock()
    private var windowNavigationIndexByWorkspace: [String: Int] = [:]
    private let browserScanCacheLock = NSLock()
    private var browserWindowScanCacheByWorkspace: [String: BrowserWindowScanCacheEntry] = [:]
    private let itermTerminalSessionLock = NSLock()
    private var itermTerminalSessionByWorkspaceAndWindowID: [String: ItermTerminalSessionMetadata] = [:]

    public init(
        store: SQLiteStore, projectsRootDirectory: URL? = nil, workspacesRootDirectory: URL? = nil,
        git: GitClient = .init(), yabai: YabaiAdapter = .init(), iterm: Iterm2Adapter = .init(), chrome: ChromeAdapter = .init(),
        browserWindowScanDebounceInterval: TimeInterval = PollingConstants.browserWindowScanDebounceInterval, currentDate: @escaping () -> Date = Date.init
    ) {
        self.store = store
        projectsRootDirectoryURL = projectsRootDirectory
        self.git = git
        self.yabai = yabai
        self.iterm = iterm
        self.chrome = chrome
        self.workspacesRootDirectoryURL = workspacesRootDirectory
        self.browserWindowScanDebounceInterval = browserWindowScanDebounceInterval
        self.currentDate = currentDate
        if ProcessInfo.processInfo.environment["DEBUG"] == "1" { fputs("muxy: DEBUG=1 enabled (browser scan/focus profiling active)\n", stderr) }
    }

    @discardableResult public func syncConfig() throws -> AppConfig {
        return try store.appConfig()
    }

    public func appConfig() throws -> AppConfig { try store.appConfig() }

    @discardableResult public func updatePortRange(_ range: PortRange) throws -> AppConfig {
        var config = try store.appConfig()
        config.portRange = range
        try store.setAppConfig(config)
        return config
    }

    public func listProjects() throws -> [ProjectSummary] {
        return try store.projects().map {
            ProjectSummary(id: $0.id, name: $0.name, dir: $0.dir, isGitRepo: $0.isGitRepo, defaultBranch: $0.defaultBranch)
        }
    }

    public func project(id: String) throws -> ProjectRecord? {
        try store.project(id: id)
    }

    @discardableResult public func updateEditorPreference(_ editor: EditorPreference?) throws -> AppConfig {
        var config = try store.appConfig()
        config.editor = editor
        try store.setAppConfig(config)
        return config
    }

    public func listWorkspaces(projectID: String, includeArchived: Bool = false) throws -> [WorkspaceSummary] {
        let records = try store.workspaces(projectID: projectID, includeArchived: includeArchived)
        return records.map {
            WorkspaceSummary(
                id: $0.id, name: $0.name, branch: $0.branch, targetBranch: $0.targetBranch, dir: $0.dir, isRunning: $0.isRunning,
                isArchived: $0.isArchived, isDefault: $0.isDefault, tooltip: $0.tooltip)
        }
    }

    public func suggestedWorkspaceName(projectID: String) throws -> String {
        guard let project = try store.project(id: projectID) else { throw MuxyError.missingProject(dir: projectID) }
        let existingNames = Set(try store.workspaces(projectID: project.id, includeArchived: true).map(\.name))
        if let suggestion = MuxyOrchestrator.suggestWorkspaceName(existingNames: existingNames) { return suggestion }
        throw MuxyError.invalidArgument(message: "No available workspace names remain for project \(project.name).")
    }

    public static func suggestWorkspaceName(existingNames: Set<String>) -> String? {
        workspaceFoodNames.first(where: { !existingNames.contains($0) })
    }

    public func gitBranchOptions(projectID: String, includeLiveRemoteHeads: Bool = true) throws -> [String] {
        guard let project = try store.project(id: projectID) else { throw MuxyError.missingProject(dir: projectID) }
        guard project.isGitRepo else { return [] }
        return git.branchOptions(path: project.dir, includeLiveRemoteHeads: includeLiveRemoteHeads)
    }

    public func workspaceGitTrackedFileActivity(workspaceID: String) throws -> GitTrackedFileActivity? {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard project.isGitRepo else { return nil }
        return git.trackedFileActivity(path: workspace.dir, baseBranch: workspace.targetBranch ?? project.defaultBranch)
    }

    private func isProtectedBranchName(_ branch: String) -> Bool {
        let normalized = branch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "main" || normalized == "master"
    }

    public func workspaceSettings(workspaceID: String) throws -> WorkspaceSettings? {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        return try loadWorkspaceSettings(project: project, workspace: workspace)
    }

    public func updateWorkspaceSettings(workspaceID: String, update: (inout WorkspaceSettings) -> Void) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard var existing = try loadWorkspaceSettings(project: project, workspace: workspace) else {
            throw MuxyError.missingProject(dir: project.dir)
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

    public func updateWorkspaceTooltip(workspaceID: String, tooltip: String?) throws {
        let (_, workspace) = try resolveWorkspace(id: workspaceID)
        try store.updateWorkspaceTooltip(id: workspace.id, tooltip: tooltip)
    }

    public func updateWorkspaceName(workspaceID: String, name: String) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw MuxyError.invalidArgument(message: "Workspace name is required.") }
        guard !workspace.isDefault || trimmedName == workspace.name else {
            throw MuxyError.invalidArgument(message: "Default workspace name cannot be changed.")
        }
        if trimmedName == workspace.name { return }
        if let existing = try store.workspace(projectID: workspace.projectID, name: trimmedName), existing.id != workspace.id {
            throw MuxyError.workspaceAlreadyExists(project: project.name, workspace: trimmedName)
        }
        try store.updateWorkspaceName(id: workspace.id, name: trimmedName)
    }

    public func updateWorkspaceMetadata(
        workspaceID: String, title: String? = nil, branch: String? = nil, directoryName: String? = nil, tooltip: String?? = nil
    ) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        var updatedName = workspace.name
        var updatedBranch = workspace.branch
        var updatedDirname = workspace.dirname
        var updatedTooltip = workspace.tooltip
        var didChange = false

        if let title {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { throw MuxyError.invalidArgument(message: "Workspace title is required.") }
            if trimmedTitle != workspace.name {
                if let existing = try store.workspace(projectID: workspace.projectID, name: trimmedTitle), existing.id != workspace.id {
                    throw MuxyError.workspaceAlreadyExists(project: project.name, workspace: trimmedTitle)
                }
                if workspace.isDefault {
                    // Default workspaces allow title overrides while default semantics remain on isDefault.
                    try store.updateWorkspaceTitle(id: workspace.id, title: trimmedTitle)
                } else {
                    updatedName = trimmedTitle
                }
                didChange = true
            }
        }

        if let branch {
            guard project.isGitRepo else {
                throw MuxyError.invalidArgument(message: "Branch can only be updated for git projects.")
            }
            let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBranch.isEmpty else { throw MuxyError.invalidArgument(message: "Workspace branch is required.") }
            if let currentBranch = workspace.branch, isProtectedBranchName(currentBranch), trimmedBranch != currentBranch {
                throw MuxyError.invalidArgument(message: "Protected branches main/master cannot be renamed.")
            }
            if trimmedBranch != workspace.branch {
                try git.renameCurrentBranch(path: workspace.dir, to: trimmedBranch)
                updatedBranch = trimmedBranch
                didChange = true
            }
        }

        if let directoryName {
            guard project.isGitRepo else {
                throw MuxyError.invalidArgument(message: "Directory name can only be updated for git projects.")
            }
            let trimmedDirectoryName = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDirectoryName.isEmpty else {
                throw MuxyError.invalidArgument(message: "Workspace directory name cannot be empty.")
            }
            try validateWorkspaceDirname(trimmedDirectoryName)
            let usedDirnames = try usedWorkspaceDirnames(project: project, excludingDirname: workspace.dirname)
            guard !usedDirnames.contains(trimmedDirectoryName) else {
                throw MuxyError.invalidArgument(message: "Workspace directory name is already in use: \(trimmedDirectoryName)")
            }
            if trimmedDirectoryName != workspace.dirname {
                updatedDirname = trimmedDirectoryName
                didChange = true
            }
        }

        if let tooltip {
            if tooltip != workspace.tooltip {
                updatedTooltip = tooltip
                didChange = true
            }
        }

        guard didChange else { return }
        if workspace.isDefault {
            if updatedBranch != workspace.branch {
                try store.updateWorkspaceBranch(id: workspace.id, branch: updatedBranch)
            }
            if updatedDirname != workspace.dirname {
                try store.updateWorkspaceDirname(id: workspace.id, dirname: updatedDirname)
            }
            if updatedTooltip != workspace.tooltip {
                try store.updateWorkspaceTooltip(id: workspace.id, tooltip: updatedTooltip)
            }
            return
        }
        let updatedWorkspace = WorkspaceRecord(
            id: workspace.id, projectID: workspace.projectID, name: updatedName, dir: workspace.dir, dirname: updatedDirname, branch: updatedBranch,
            targetBranch: workspace.targetBranch, isDefault: workspace.isDefault, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
            lastLaunchedAt: workspace.lastLaunchedAt, tooltip: updatedTooltip)
        try store.upsert(workspace: updatedWorkspace)
    }

    public func addProject(dir: String) throws -> ProjectRecord {
        let normalizedDir = normalizePath(dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedDir, isDirectory: &isDir), isDir.boolValue else {
            throw MuxyError.invalidArgument(message: "Project directory not found: \(normalizedDir)")
        }
        if try store.project(dir: normalizedDir) != nil {
            throw MuxyError.projectAlreadyExists(dir: normalizedDir)
        }
        let record = try normalizeDir(normalizedDir)
        try store.upsert(project: record)
        try ensureDefaultWorkspace(for: record)
        return record
    }

    public func addProject(gitURL: String) throws -> ProjectRecord {
        let trimmedURL = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { throw MuxyError.invalidArgument(message: "Git repository URL is required.") }
        let inferredName = inferredProjectName(from: trimmedURL)
        let projectDirname = sanitizeDirname(inferredName, fallback: "project")
        let destination = repositoriesRootDirectory().appending(path: projectDirname, directoryHint: .isDirectory)
        let normalizedDestination = normalizePath(destination.path)

        if try store.project(dir: normalizedDestination) != nil {
            throw MuxyError.projectAlreadyExists(dir: normalizedDestination)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw MuxyError.invalidArgument(message: "Project directory already exists: \(normalizedDestination)")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git.clone(url: trimmedURL, destination: destination.path, bare: true)

        let defaultBranch = try preferredImportedDefaultBranch(path: destination.path)
        let record = ProjectRecord(
            id: normalizedDestination, name: destination.lastPathComponent, dir: normalizedDestination, isGitRepo: true, defaultBranch: defaultBranch)
        try store.upsert(project: record)
        try ensureImportedGitDefaultWorkspace(for: record, branch: defaultBranch)
        return record
    }

    public func updateProjectConfig(projectID: String, update: (inout ProjectRecord) -> Void) throws {
        let normalizedID = normalizePath(projectID)
        guard var record = try store.project(id: normalizedID) else {
            throw MuxyError.missingProject(dir: normalizedID)
        }
        let previousRecord = record
        update(&record)
        record = ProjectRecord(
            id: normalizedID, name: record.name, dir: record.dir, isGitRepo: record.isGitRepo,
            defaultBranch: record.defaultBranch, setupScript: record.setupScript, stopScript: record.stopScript,
            ports: record.ports, processes: record.processes,
            statusChecks: record.statusChecks, browserSessions: record.browserSessions)
        try store.upsert(project: record)
        try ensureDefaultWorkspace(for: record)
        try syncDefaultWorkspaceSettingsIfTemplateBased(project: record, previousRecord: previousRecord, updatedRecord: record)
    }

    public func removeProject(dir: String) throws {
        let normalizedDir = normalizePath(dir)
        if let project = try store.project(dir: normalizedDir) {
            let workspaces = try store.workspaces(projectID: project.id, includeArchived: true)
            try removeManagedGitWorktreesIfNeeded(project: project, workspaces: workspaces)
            try store.deleteProject(id: project.id)
            try removeManagedGitWorkspaceDirectoriesIfNeeded(project: project)
            try removeManagedProjectDirectoryIfNeeded(project: project)
        }
    }

    public func createWorkspace(
        projectID: String, name: String, branch: String? = nil, targetBranch: String? = nil, directoryName: String? = nil,
        runSetupScript: Bool = true, allowRemoteBranchLookup: Bool = true)
        throws -> WorkspaceRecord
    {
        guard let project = try store.project(id: projectID) else { throw MuxyError.missingProject(dir: projectID) }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw MuxyError.invalidArgument(message: "Workspace name is required.") }
        let trimmedDirectoryName = directoryName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBranch: String?
        let resolvedTargetBranch: String?
        if project.isGitRepo {
            guard let trimmedBranch, !trimmedBranch.isEmpty else {
                throw MuxyError.invalidArgument(message: "Branch name is required for git projects.")
            }
            resolvedBranch = trimmedBranch
            resolvedTargetBranch = try resolveWorkspaceTargetBranch(project: project, targetBranch: targetBranch)
        } else {
            if let trimmedDirectoryName, !trimmedDirectoryName.isEmpty {
                throw MuxyError.invalidArgument(message: "Directory name override is only supported for git projects.")
            }
            resolvedBranch = nil
            resolvedTargetBranch = nil
        }
        if let existing = try store.workspace(projectID: projectID, name: trimmedName) {
            if !existing.isArchived { throw MuxyError.workspaceAlreadyExists(project: project.name, workspace: trimmedName) }
            let revivedDir: String
            let revivedDirname: String?
            let revivedBranch: String?
            if project.isGitRepo {
                guard let branchName = resolvedBranch else {
                    throw MuxyError.invalidArgument(message: "Branch name is required for git projects.")
                }
                let dirname = try makeWorkspaceDirname(project: project, existingDirname: existing.dirname, requestedDirname: trimmedDirectoryName)
                revivedDirname = dirname
                let worktreeRoot = try worktreeRoot(project: project)
                try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
                revivedDir = worktreeRoot.appendingPathComponent(dirname, isDirectory: true).path
                if !FileManager.default.fileExists(atPath: revivedDir) {
                    try git.createWorktree(
                        path: project.dir,
                        worktreePath: revivedDir,
                        branch: branchName,
                        targetBranch: resolvedTargetBranch,
                        allowRemoteBranchLookup: allowRemoteBranchLookup)
                }
                revivedBranch = branchName
            } else {
                revivedDir = project.dir
                revivedDirname = nil
                revivedBranch = nil
            }
            let revived = WorkspaceRecord(
                id: existing.id, projectID: project.id, name: trimmedName, dir: revivedDir, dirname: revivedDirname, branch: revivedBranch,
                targetBranch: existing.targetBranch ?? resolvedTargetBranch, isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
            try store.upsert(workspace: revived)
            try seedWorkspaceSettings(project: project, workspace: revived)
            try initializeWorkspaceRuntime(project: project, workspace: revived, runSetupScript: runSetupScript)
            return revived
        }
        let workspaceDir: String
        let workspaceDirname: String?
        let workspaceBranch: String?
        if project.isGitRepo {
            guard let branchName = resolvedBranch else { throw MuxyError.invalidArgument(message: "Branch name is required for git projects.") }
            let dirname = try makeWorkspaceDirname(project: project, existingDirname: nil, requestedDirname: trimmedDirectoryName)
            workspaceDirname = dirname
            let worktreeRoot = try worktreeRoot(project: project)
            try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
            workspaceDir = worktreeRoot.appendingPathComponent(dirname, isDirectory: true).path
            try git.createWorktree(
                path: project.dir,
                worktreePath: workspaceDir,
                branch: branchName,
                targetBranch: resolvedTargetBranch,
                allowRemoteBranchLookup: allowRemoteBranchLookup)
            workspaceBranch = branchName
        } else {
            workspaceDir = project.dir
            workspaceDirname = nil
            workspaceBranch = nil
        }
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, name: trimmedName, dir: workspaceDir, dirname: workspaceDirname, branch: workspaceBranch,
            targetBranch: resolvedTargetBranch, isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        try seedWorkspaceSettings(project: project, workspace: workspace)
        try initializeWorkspaceRuntime(project: project, workspace: workspace, runSetupScript: runSetupScript)

        return workspace
    }

    private func resolveWorkspaceTargetBranch(project: ProjectRecord, targetBranch: String?) throws -> String {
        if let targetBranch = targetBranch?.trimmingCharacters(in: .whitespacesAndNewlines), !targetBranch.isEmpty { return targetBranch }
        if let configured = project.defaultBranch, !configured.isEmpty { return configured }
        if git.branchExists(path: project.dir, branch: "main") || git.remoteBranchExists(path: project.dir, branch: "main") { return "main" }
        if git.branchExists(path: project.dir, branch: "master") || git.remoteBranchExists(path: project.dir, branch: "master") { return "master" }
        throw MuxyError.invalidArgument(message: "Target branch is required for git projects.")
    }

    public func createWorkspaceFromWorktree(worktreePath: String, name: String? = nil) throws -> WorkspaceRecord {
        let normalizedWorktreePath = normalizePath(worktreePath)
        guard FileManager.default.fileExists(atPath: normalizedWorktreePath) else {
            throw MuxyError.invalidArgument(message: "Worktree path does not exist: \(normalizedWorktreePath)")
        }
        guard git.isRepo(path: normalizedWorktreePath) else {
            throw MuxyError.invalidArgument(message: "Path is not a git repository: \(normalizedWorktreePath)")
        }
        
        let gitCommonDirOutput = try git.runGitAndCapture(["-C", normalizedWorktreePath, "rev-parse", "--git-common-dir"])
        let gitCommonDir = gitCommonDirOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let gitCommonDirURL = URL(fileURLWithPath: gitCommonDir, relativeTo: URL(fileURLWithPath: normalizedWorktreePath))
            .standardized
        let gitRoot = gitCommonDirURL.deletingLastPathComponent().path
        let projectID = normalizePath(gitRoot)
        
        guard let project = try store.project(id: projectID) else {
            throw MuxyError.invalidArgument(
                message: "Project not found for git root: \(gitRoot). Add the project first using: mx project add --dir \(gitRoot)")
        }
        
        if let existing = try store.workspace(dir: normalizedWorktreePath) {
            if existing.isArchived {
                throw MuxyError.invalidArgument(
                    message: "Workspace already exists but is archived: \(existing.name). Unarchive it or use a different worktree.")
            }
            throw MuxyError.invalidArgument(message: "Workspace already exists: \(existing.name)")
        }
        
        let branchOutput = try git.runGitAndCapture(["-C", normalizedWorktreePath, "rev-parse", "--abbrev-ref", "HEAD"])
        let branch = branchOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let inferredName: String
        if let providedName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !providedName.isEmpty {
            inferredName = providedName
        } else {
            inferredName = branch
        }
        
        if let existing = try store.workspace(projectID: projectID, name: inferredName), !existing.isArchived {
            throw MuxyError.workspaceAlreadyExists(project: project.name, workspace: inferredName)
        }
        
        let dirname = URL(fileURLWithPath: normalizedWorktreePath).lastPathComponent
        
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, name: inferredName, dir: normalizedWorktreePath, dirname: dirname, branch: branch,
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        try seedWorkspaceSettings(project: project, workspace: workspace)
        try initializeWorkspaceRuntime(project: project, workspace: workspace, runSetupScript: true)
        
        return workspace
    }

    public func scanAndCreateWorkspacesFromWorktrees(projectID: String? = nil) throws -> [WorkspaceRecord] {
        let projects: [ProjectRecord]
        if let projectID {
            guard let project = try store.project(id: projectID) else {
                throw MuxyError.missingProject(dir: projectID)
            }
            projects = [project]
        } else {
            projects = try store.projects()
        }
        
        var createdWorkspaces: [WorkspaceRecord] = []
        
        for project in projects where project.isGitRepo {
            let worktrees = try git.listWorktrees(path: project.dir)
            var discoverableWorktreeByPath: [String: WorktreeInfo] = [:]
            for worktree in worktrees {
                let normalizedPath = normalizePath(worktree.path)
                guard isDiscoverableWorktreePath(project: project, path: normalizedPath) else {
                    continue
                }
                discoverableWorktreeByPath[normalizedPath] = worktree
            }

            let existingWorkspaces = try store.workspaces(projectID: project.id, includeArchived: true)
            for workspace in existingWorkspaces {
                let normalizedWorkspacePath = normalizePath(workspace.dir)
                if let worktree = discoverableWorktreeByPath[normalizedWorkspacePath], workspace.branch != worktree.branchName {
                    let updatedWorkspace = WorkspaceRecord(
                        id: workspace.id, projectID: workspace.projectID, name: workspace.name, dir: workspace.dir, dirname: workspace.dirname,
                        branch: worktree.branchName, targetBranch: workspace.targetBranch, isDefault: workspace.isDefault, isArchived: workspace.isArchived,
                        isRunning: workspace.isRunning, lastLaunchedAt: workspace.lastLaunchedAt, tooltip: workspace.tooltip)
                    try store.upsert(workspace: updatedWorkspace)
                }

                guard !workspace.isArchived, !workspace.isDefault else {
                    continue
                }
                guard discoverableWorktreeByPath[normalizedWorkspacePath] == nil else {
                    continue
                }
                try archiveWorkspaceBecauseWorktreeIsInvalid(workspaceID: workspace.id)
            }
            
            for worktree in worktrees {
                let normalizedPath = normalizePath(worktree.path)

                guard isDiscoverableWorktreePath(project: project, path: normalizedPath) else {
                    continue
                }

                if try store.isIgnoredWorktree(path: normalizedPath) {
                    continue
                }
                
                if let _ = try store.workspace(dir: normalizedPath) {
                    continue
                }
                
                guard let branchName = worktree.branchName else {
                    continue
                }
                
                let workspace = WorkspaceRecord(
                    id: UUID().uuidString, projectID: project.id, name: branchName, dir: normalizedPath,
                    dirname: URL(fileURLWithPath: normalizedPath).lastPathComponent, branch: branchName,
                    isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
                try store.upsert(workspace: workspace)
                try seedWorkspaceSettings(project: project, workspace: workspace)
                try initializeWorkspaceRuntime(project: project, workspace: workspace, runSetupScript: true)
                
                createdWorkspaces.append(workspace)
            }
        }
        
        return createdWorkspaces
    }

    private func archiveWorkspaceBecauseWorktreeIsInvalid(workspaceID: String) throws {
        let (_, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isArchived else { return }
        _ = try stopWorkspaceUnlocked(workspaceID: workspaceID)
        try PortAllocator(store: store).releasePorts(workspaceID: workspace.id)
        try store.updateWorkspaceArchived(id: workspace.id, isArchived: true)
    }

    private func isDiscoverableWorktreePath(project: ProjectRecord, path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        guard git.isRepo(path: path) else { return false }
        do {
            let gitCommonDirOutput = try git.runGitAndCapture(["-C", path, "rev-parse", "--git-common-dir"])
            let gitCommonDir = gitCommonDirOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let gitCommonDirURL = URL(fileURLWithPath: gitCommonDir, relativeTo: URL(fileURLWithPath: path)).standardized
            let gitRoot = normalizePath(gitCommonDirURL.deletingLastPathComponent().path)
            return gitRoot == project.id
        } catch {
            return false
        }
    }

    public func launchWorkspace(workspaceID: String) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) { try launchWorkspaceUnlocked(workspaceID: workspaceID) }
    }

    public func restartWorkspace(workspaceID: String) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            _ = try stopWorkspaceUnlocked(workspaceID: workspaceID)
            try launchWorkspaceUnlocked(workspaceID: workspaceID)
        }
    }

    public func upWorkspace(workspaceID: String, restartIfRunning: Bool = false, background: Bool = false) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            let (_, workspace) = try resolveWorkspace(id: workspaceID)
            guard !workspace.isArchived else { throw MuxyError.invalidArgument(message: "Workspace is archived.") }
            let hasTrackedRuntime = try hasTrackedRuntimeIndicators(workspaceID: workspace.id)
            if workspace.isRunning || hasTrackedRuntime {
                if restartIfRunning {
                    _ = try stopWorkspaceUnlocked(workspaceID: workspaceID)
                    try launchWorkspaceUnlocked(workspaceID: workspaceID, background: background)
                } else {
                    try restartExitedProcesses(workspaceID: workspaceID, background: background)
                }
                return
            }
            try launchWorkspaceUnlocked(workspaceID: workspaceID, background: background)
        }
    }

    private func launchWorkspaceUnlocked(workspaceID: String, background: Bool = false) throws {
        try waitForWorkspaceSetupToComplete(workspaceID: workspaceID)
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isArchived else { throw MuxyError.invalidArgument(message: "Workspace is archived.") }
        let hasTrackedRuntime = try hasTrackedRuntimeIndicators(workspaceID: workspace.id)
        guard !(workspace.isRunning || hasTrackedRuntime) else {
            throw MuxyError.invalidArgument(message: "Workspace is already running. Use restart.")
        }
        let config = try loadWorkspaceSettings(project: project, workspace: workspace)
        let portDefinitions = try store.workspacePortDefinitions(workspaceID: workspace.id)
        let ports = try store.workspacePorts(workspaceID: workspace.id)
        if ports.count != portDefinitions.count {
            let portRange = try store.appConfig().portRange
            _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, definitions: portDefinitions, range: portRange)
        } else {
            try PortAllocator(store: store).reserveExistingPorts(workspaceID: workspace.id)
        }

        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: try store.workspacePortsNamed(workspaceID: workspace.id))

        var newWindows: [WindowRecord] = []
        var windowSnapshot = try yabai.listWindows()

        if let config {
            try launchProcesses(workspace: workspace, templates: config.processes, env: env, background: background)
            let capturedTerminals = try captureNewWindows(
                snapshot: windowSnapshot, role: "terminal", appName: "iTerm2", workspaceID: workspace.id, orderOffset: 200)
            newWindows.append(contentsOf: capturedTerminals)
            let ensuredTerminals = try terminalWindowsFromRunningProcesses(workspace: workspace, existingWindows: newWindows)
            newWindows.append(contentsOf: ensuredTerminals)
            windowSnapshot = try yabai.listWindows()

            let browserSessionResult = try ensureBrowserSessions(
                project: project, workspace: workspace, sessions: config.browserSessions, env: env, extractOnAttach: true,
                background: background)
            try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: browserSessionResult.sessions)
            newWindows.append(contentsOf: browserSessionResult.windows)
            newWindows.append(
                contentsOf: try captureNewWindows(
                    snapshot: windowSnapshot, role: "browser", appName: "Google Chrome", workspaceID: workspace.id, orderOffset: 0))
            windowSnapshot = try yabai.listWindows()
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

    @discardableResult public func stopWorkspace(workspaceID: String) throws -> WorkspaceStopOutcome {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) { try stopWorkspaceUnlocked(workspaceID: workspaceID) }
    }

    private func stopWorkspaceUnlocked(workspaceID: String) throws -> WorkspaceStopOutcome {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let windows = try trackedWindows(workspaceID: workspace.id)
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        let processes = try store.runningProcesses(workspaceID: workspace.id)
        var skippedStopScriptBecauseWorkspaceDirectoryMissing = false
        for process in processes { if let pid = resolvedRuntimePID(for: process) { terminateProcessGroup(pid: pid) } }
        if let script = settings?.stopScript?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty {
            if directoryExists(at: workspace.dir) {
                do {
                    try runScript(applyEnvVars(script, env: env), cwd: workspace.dir)
                } catch {
                    if isMissingDirectoryError(error) {
                        skippedStopScriptBecauseWorkspaceDirectoryMissing = true
                    } else {
                        throw error
                    }
                }
            } else {
                skippedStopScriptBecauseWorkspaceDirectoryMissing = true
            }
        }
        // Always preserve coding agent sessions: collect their iTerm2 session IDs to skip when closing windows.
        let agentWindowsList = (try? store.agentWindows(workspaceID: workspace.id)) ?? []
        let agentItermSessionIDs = Set(agentWindowsList.compactMap { $0.itermSessionID })
        var processTerminalWindowIDs = Set<Int>()
        var closedProcessTerminalWindowIDs = Set<Int>()
        for process in processes where process.terminalApp == "iTerm2" {
            let didClose = (try? closeTrackedItermTerminalContainer(process)) ?? false
            if let windowID = process.windowID {
                processTerminalWindowIDs.insert(windowID)
                if didClose { closedProcessTerminalWindowIDs.insert(windowID) }
            }
        }
        var closedWindowIDs = closedProcessTerminalWindowIDs
        for window in windows {
            if window.role == "browser" {
                closeTrackedBrowserTab(window)
                continue
            }
            if window.role == "terminal", window.app == "iTerm2", let id = window.windowID {
                if closedWindowIDs.contains(id) { continue }
                if !processTerminalWindowIDs.contains(id) {
                    // Skip closing this specific session if it belongs to a coding agent.
                    let isAgentSession = window.itermSessionID.map({ agentItermSessionIDs.contains($0) }) == true
                    if !isAgentSession {
                        _ = try? closeTrackedItermTerminalWindow(workspaceID: workspace.id, windowID: id)
                    }
                }
                closedWindowIDs.insert(id)
                continue
            }
            if window.role == "terminal", let id = window.windowID, processTerminalWindowIDs.contains(id) { continue }
            if let id = window.windowID, !closedWindowIDs.contains(id) {
                closedWindowIDs.insert(id)
                _ = try? yabai.closeWindow(id: id)
            }
        }
        try store.deleteRunningProcesses(workspaceID: workspace.id)
        try store.deleteWindows(workspaceID: workspace.id)
        clearItermTerminalSessionMetadata(workspaceID: workspace.id)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: false, launchedAt: workspace.lastLaunchedAt)
        setWindowNavigationIndex(nil, workspaceID: workspace.id)
        return WorkspaceStopOutcome(skippedStopScriptBecauseWorkspaceDirectoryMissing: skippedStopScriptBecauseWorkspaceDirectoryMissing)
    }

    public func archiveWorkspace(workspaceID: String) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) { try archiveWorkspaceUnlocked(workspaceID: workspaceID) }
    }

    private func archiveWorkspaceUnlocked(workspaceID: String) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isDefault else { throw MuxyError.invalidArgument(message: "Default workspace cannot be archived.") }
        _ = try stopWorkspaceUnlocked(workspaceID: workspaceID)
        try store.deleteAgentWindows(workspaceID: workspaceID)
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
            throw MuxyError.invalidArgument(message: "Workspace action is already in progress.")
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
    
    public func checkAndUpdateProcessStatuses() throws -> Bool {
        var didUpdate = false
        let allProjects = try store.projects()
        let now = currentDate()
        
        for project in allProjects {
            let workspaces = try store.workspaces(projectID: project.id, includeArchived: false)
            
            for workspace in workspaces {
                let processes = try store.runningProcesses(workspaceID: workspace.id)
                
                for process in processes where process.status == .running {
                    if let startedAtStr = process.startedAt, let startedAt = ISO8601DateFormatter().date(from: startedAtStr) {
                        let secondsSinceStart = now.timeIntervalSince(startedAt)
                        if secondsSinceStart < 10.0 {
                            continue
                        }
                    }
                    
                    guard let pid = resolvedRuntimePID(for: process) else { continue }
                    
                    if !isProcessAlive(pid: pid) {
                        let updatedProcess = RunningProcessRecord(
                            id: process.id, workspaceID: process.workspaceID, templateName: process.templateName,
                            command: process.command, terminalApp: process.terminalApp, windowID: process.windowID,
                            itermSessionID: process.itermSessionID, itermTabIndex: process.itermTabIndex,
                            pid: process.pid, status: .exited, logPath: process.logPath,
                            lastOutputAt: process.lastOutputAt, startedAt: process.startedAt,
                            exitedAt: nowISO8601()
                        )
                        try store.upsert(runningProcess: updatedProcess)
                        // Mark status check results as failed so they reflect the process exit.
                        try store.markStatusResultsAsFailed(processID: process.id)
                        didUpdate = true

                        // Handle on-exit behavior for the process
                        try handleProcessExit(workspaceID: workspace.id, process: updatedProcess, project: project, workspace: workspace)
                    }
                }
            }
        }
        
        // Prune stale iTerm2 agent sessions
        var aliveItermSessionIDs: Set<String>? = nil
        for project in allProjects {
            let workspaces = try store.workspaces(projectID: project.id, includeArchived: false)
            for workspace in workspaces {
                let agentWindowsList = (try? store.agentWindows(workspaceID: workspace.id)) ?? []
                let itermAgents = agentWindowsList.filter { $0.provider == .iterm2 }
                guard !itermAgents.isEmpty else { continue }
                if aliveItermSessionIDs == nil {
                    // Leave nil on failure so the guard below skips pruning this cycle.
                    aliveItermSessionIDs = try? iterm.listSessionIDs()
                }
                guard let aliveIDs = aliveItermSessionIDs else { continue }
                for agent in itermAgents {
                    guard let sid = agent.itermSessionID else {
                        try? store.deleteAgentWindow(id: agent.id)
                        continue
                    }
                    if !aliveIDs.contains(sid) {
                        try? store.deleteAgentWindow(id: agent.id)
                        didUpdate = true
                    }
                }
            }
        }

        return didUpdate
    }

    public func runStatusChecks(workspaceID: String, dueOnly: Bool = false, now: Date = Date()) throws -> [StatusResult] {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard let config = try loadWorkspaceSettings(project: project, workspace: workspace) else {
            return []
        }
        let processes = try store.runningProcesses(workspaceID: workspaceID)
        let checksByProcessID = Dictionary(grouping: config.statusChecks, by: \.process)
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspaceID)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        var results: [StatusResult] = []
        let iso8601 = ISO8601DateFormatter()
        for process in processes where process.status == .running {
            guard let checks = checksByProcessID[process.templateName], !checks.isEmpty else { continue }
            let existingResults = Dictionary(uniqueKeysWithValues: try store.statusResults(processID: process.id).map { ($0.checkName, $0) })
            for check in checks {
                let checkName = check.name ?? check.process
                if dueOnly,
                    let existing = existingResults[checkName],
                    let lastRunAt = existing.lastRunAt,
                    let lastRunDate = iso8601.date(from: lastRunAt),
                    now.timeIntervalSince(lastRunDate) < TimeInterval(max(check.interval, 1))
                {
                    continue
                }

                let resolvedCommand = applyEnvVars(check.command, env: env)
                let outcome = try runCommandWithTimeout(command: resolvedCommand, cwd: workspace.dir, timeout: check.timeout, env: env)
                let status: StatusCheckStatus = outcome.exitCode == 0 ? .passed : .failed
                let result = StatusResult(
                    processID: process.id, checkName: checkName, status: status, message: outcome.output.isEmpty ? nil : outcome.output,
                    lastRunAt: nowISO8601())
                try store.upsert(statusResult: result)
                results.append(result)

                // Handle onFail behavior for failed status checks
                if outcome.exitCode != 0 {
                    try handleStatusCheckFailure(workspaceID: workspaceID, process: process, check: check, result: result)
                }
            }
        }
        return results
    }

    public func runDueStatusChecksForRunningWorkspaces(now: Date = Date()) throws -> Bool {
        var didRunChecks = false
        let allProjects = try store.projects()
        for project in allProjects {
            let workspaces = try store.workspaces(projectID: project.id, includeArchived: false)
            for workspace in workspaces where workspace.isRunning {
                let results = try runStatusChecks(workspaceID: workspace.id, dueOnly: true, now: now)
                if !results.isEmpty { didRunChecks = true }
            }
        }
        return didRunChecks
    }
    
    private func deliverNotification(title: String, body: String, subtitle: String? = nil) {
        guard NSClassFromString("XCTest") == nil else {
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let subtitle {
            content.subtitle = subtitle
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                center.add(request) { error in
                    if let error {
                        fputs("muxy: Failed to deliver notification: \(error.localizedDescription)\n", stderr)
                    }
                }
            }
        }
    }
    
    private func handleStatusCheckFailure(workspaceID: String, process: RunningProcessRecord, check: StatusCheckDefinition, result: StatusResult) throws {
        switch check.onFail {
        case .none:
            // Do nothing - just log the failure
            break
            
        case .notify:
            deliverNotification(
                title: "Status Check Failed",
                body: "Process '\(process.templateName)' check '\(result.checkName)' failed",
                subtitle: result.message
            )
            
        case .restart:
            // Restart the process
            try restartFailedProcess(workspaceID: workspaceID, process: process, check: check, result: result)
        }
    }
    
    private func restartFailedProcess(workspaceID: String, process: RunningProcessRecord, check: StatusCheckDefinition, result: StatusResult) throws {
        // Log the restart attempt
        fputs("muxy: Restarting process '\(process.templateName)' due to failed status check '\(result.checkName)'\n", stderr)
        
        // Show notification about restart
        deliverNotification(
            title: "Process Restarting",
            body: "Process '\(process.templateName)' is being restarted due to failed status check",
            subtitle: result.message.map { "Reason: \($0)" }
        )

        // Mark the process as exited in the database
        let updatedProcess = RunningProcessRecord(
            id: process.id, workspaceID: process.workspaceID, templateName: process.templateName,
            command: process.command, terminalApp: process.terminalApp, windowID: process.windowID,
            itermSessionID: process.itermSessionID, itermTabIndex: process.itermTabIndex,
            pid: process.pid, status: .exited, logPath: process.logPath,
            lastOutputAt: process.lastOutputAt, startedAt: process.startedAt,
            exitedAt: nowISO8601()
        )
        try store.upsert(runningProcess: updatedProcess)
        
        // Restart the process in a new terminal
        try restartProcessInTerminal(workspaceID: workspaceID, process: process)
    }
    
    private func handleProcessExit(workspaceID: String, process: RunningProcessRecord, project: ProjectRecord, workspace: WorkspaceRecord) throws {
        // Find the process template to get the on-exit behavior
        guard let config = try loadWorkspaceSettings(project: project, workspace: workspace) else {
            return
        }
        
        guard let processTemplate = config.processes.first(where: { ($0.name ?? $0.command) == process.templateName }) else {
            return
        }
        
        switch processTemplate.onExit {
        case .none:
            // Do nothing - just log the exit
            break
            
        case .notify:
            deliverNotification(
                title: "Process Exited",
                body: "Process '\(process.templateName)' has exited",
                subtitle: nil
            )
            
        case .restart:
            // Restart the process
            fputs("muxy: Restarting process '\(process.templateName)' due to exit\n", stderr)
            
            deliverNotification(
                title: "Process Restarting",
                body: "Process '\(process.templateName)' is being restarted",
                subtitle: nil
            )
            
            try restartProcessInTerminal(workspaceID: workspaceID, process: process)
        }
    }
    
    private func restartExitedProcesses(workspaceID: String, background: Bool) throws {
        let processes = try store.runningProcesses(workspaceID: workspaceID)
        for process in processes where process.status == .exited {
            try restartProcessInTerminal(workspaceID: workspaceID, process: process, background: background)
        }
    }

    private func restartProcessInTerminal(workspaceID: String, process: RunningProcessRecord, background: Bool = false) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspaceID)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        let didTerminate = terminateProcessForRestart(process)
        
        // Prepare the command with proper environment and PID tracking
        let (logFile, pidFile) = try processRuntimePaths(workspaceID: workspace.id, name: process.templateName)
        let command = shellCommand(base: process.command, cwd: workspace.dir, env: env, logFile: logFile, pidFile: pidFile)
        
        if didTerminate, let windowID = process.windowID, process.terminalApp == "iTerm2" {
            // Reuse existing terminal window
            fputs("muxy: Restarting process '\(process.templateName)' in existing terminal window \(windowID)\n", stderr)
            try iterm.runInWindow(id: windowID, command: command)
            
            // Read the new PID from the PID file and update the process record
            let newPID = try? Int(String(contentsOfFile: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))
            
            let restartedProcess = RunningProcessRecord(
                id: process.id, workspaceID: process.workspaceID, templateName: process.templateName,
                command: process.command, terminalApp: process.terminalApp, windowID: windowID,
                itermSessionID: process.itermSessionID, itermTabIndex: process.itermTabIndex,
                pid: newPID, status: .running, logPath: process.logPath,
                lastOutputAt: nil, startedAt: nowISO8601(), exitedAt: nil
            )
            try store.upsert(runningProcess: restartedProcess)
        } else {
            // Fallback: create new terminal window when there is no reusable window or shutdown did not complete.
            fputs("muxy: Creating new terminal window for process '\(process.templateName)'\n", stderr)
            let windowInfo = try iterm.openWindowAndRun(command: command, background: background)
            let windowID = windowInfo.id
            
            // Read the new PID from the PID file and update the process record
            let newPID = try? Int(String(contentsOfFile: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))
            
            let restartedProcess = RunningProcessRecord(
                id: process.id, workspaceID: process.workspaceID, templateName: process.templateName,
                command: process.command, terminalApp: "iTerm2", windowID: windowID,
                itermSessionID: windowInfo.sessionID, itermTabIndex: windowInfo.tabIndex,
                pid: newPID, status: .running, logPath: process.logPath,
                lastOutputAt: nil, startedAt: nowISO8601(), exitedAt: nil
            )
            if windowID > 0 {
                setItermTerminalSessionMetadata(
                    workspaceID: process.workspaceID, windowID: windowID, sessionID: windowInfo.sessionID, tabIndex: windowInfo.tabIndex)
            }
            try store.upsert(runningProcess: restartedProcess)
        }
    }

    private func terminateProcessForRestart(_ process: RunningProcessRecord) -> Bool {
        guard let pid = resolvedRuntimePID(for: process) else { return true }
        terminateProcessGroup(pid: pid)
        waitForProcessExit(pid: pid, timeout: 10.0)
        guard isProcessAlive(pid: pid) else { return true }
        fputs(
            "muxy: Process '\(process.templateName)' with pid \(pid) did not exit in time; restart will use a new terminal window\n",
            stderr
        )
        return false
    }

    public func statusResults(processID: String) throws -> [StatusResult] { try store.statusResults(processID: processID) }

    public func windows(workspaceID: String) throws -> [WindowRecord] { try trackedWindows(workspaceID: workspaceID) }

    public struct RefreshResult: Sendable {
        public let didMutateDB: Bool
        public let trackedWindowCounts: [String: Int]
    }

    @discardableResult
    public func refreshWorkspaceWindows(workspaceID: String) throws -> Bool {
        _ = try trackedWindows(workspaceID: workspaceID)
        let refreshedTerminalTitles = try refreshUnmanagedTerminalWindowTitles(workspaceID: workspaceID)
        let pruned = try pruneMissingWindows(workspaceID: workspaceID)
        var didMutate = refreshedTerminalTitles > 0 || pruned > 0
        guard let workspace = try store.workspace(id: workspaceID), workspace.isRunning else { return didMutate }
        let hasRuntimeIndicators = try hasTrackedRuntimeIndicators(workspaceID: workspaceID)
        if !hasRuntimeIndicators {
            try store.updateWorkspaceRunning(id: workspaceID, isRunning: false, launchedAt: workspace.lastLaunchedAt)
            setWindowNavigationIndex(nil, workspaceID: workspaceID)
            didMutate = true
        }
        return didMutate
    }

    @discardableResult
    private func refreshUnmanagedTerminalWindowTitles(workspaceID: String) throws -> Int {
        let windows = try store.windows(workspaceID: workspaceID)
        let processWindowIDs = Set(try store.runningProcesses(workspaceID: workspaceID).compactMap(\.windowID))
        let terminalWindowsToRefresh = windows.filter { window in
            guard window.role == "terminal", let windowID = window.windowID else { return false }
            return !processWindowIDs.contains(windowID)
        }
        guard !terminalWindowsToRefresh.isEmpty else { return 0 }

        let liveWindowsByID = Dictionary(uniqueKeysWithValues: try yabai.listWindows().map { ($0.id, $0) })
        var refreshedCount = 0
        for window in terminalWindowsToRefresh {
            guard let windowID = window.windowID, let liveWindow = liveWindowsByID[windowID] else { continue }
            let refreshedTitle = liveWindow.title
            let refreshedApp = liveWindow.app
            guard window.title != refreshedTitle || window.app != refreshedApp else { continue }
            let refreshedWindow = WindowRecord(
                id: window.id, workspaceID: window.workspaceID, app: refreshedApp, title: refreshedTitle, targetURL: window.targetURL,
                windowID: windowID, itermSessionID: window.itermSessionID, itermTabIndex: window.itermTabIndex,
                role: window.role, orderIndex: window.orderIndex, lastSeenAt: window.lastSeenAt)
            try store.upsert(window: refreshedWindow)
            refreshedCount += 1
        }
        return refreshedCount
    }

    public func refreshAllWorkspaceWindows() throws -> RefreshResult {
        var didMutate = false
        var trackedCounts: [String: Int] = [:]
        for project in try store.projects() {
            let workspaces = try store.workspaces(projectID: project.id, includeArchived: false)
            for workspace in workspaces {
                if try refreshWorkspaceWindows(workspaceID: workspace.id) { didMutate = true }
                let tracked = try trackedWindows(workspaceID: workspace.id)
                trackedCounts[workspace.id] = tracked.count
            }
        }
        return RefreshResult(didMutateDB: didMutate, trackedWindowCounts: trackedCounts)
    }

    public func workspacePorts(workspaceID: String) throws -> [Int] { try store.workspacePorts(workspaceID: workspaceID) }

    public func workspacePortsNamed(workspaceID: String) throws -> [(port: Int, name: String)] {
        try store.workspacePortsNamed(workspaceID: workspaceID)
    }

    public func openWorkspaceEditor(workspaceID: String) throws {
        let (_, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isArchived else { throw MuxyError.invalidArgument(message: "Workspace is archived.") }
        guard let editor = try store.appConfig().editor, editor != .none else {
            throw MuxyError.configError(message: "Preferred editor is not configured.")
        }
        try EditorLauncher.open(editor: editor, directory: workspace.dir)
    }

    public func openWorkspaceTerminal(workspaceID: String) throws {
        let (_, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isArchived else { throw MuxyError.invalidArgument(message: "Workspace is archived.") }
        guard iterm.isAvailable() else { throw MuxyError.dependencyMissing(message: "iTerm2 is required to open terminal windows.") }
        let snapshot = try yabai.listWindows()
        let escapedDir = workspace.dir.replacingOccurrences(of: "\"", with: "\\\"")
        let window = try iterm.openWindowAndRun(command: "cd \"\(escapedDir)\"")
        if let focused = try yabai.focusedWindow(), focused.app == "iTerm2" {
            setItermTerminalSessionMetadata(
                workspaceID: workspace.id, windowID: focused.id, sessionID: window.sessionID, tabIndex: window.tabIndex)
        }
        try attachNewWindows(snapshot: snapshot, workspaceID: workspace.id, role: "terminal", appName: "iTerm2", orderOffset: 200)
        if let focused = try yabai.focusedWindow(), focused.app == "iTerm2" {
            try persistItermTerminalWindowMetadata(
                workspaceID: workspace.id, windowID: focused.id, sessionID: window.sessionID, tabIndex: window.tabIndex)
        }
        if !workspace.isRunning {
            let launchedAt = workspace.lastLaunchedAt ?? nowISO8601()
            try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: launchedAt)
        }
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
        if let workspaceID = try store.workspaceID(windowID: focused.id) { return workspaceID }
        return try store.workspaceIDForAgentWindow(yabaiWindowID: focused.id)
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
        if window.role == "terminal", let trackedWindowID = window.windowID, window.app == "iTerm2" {
            let focusedIterm = (try? focusItermTerminalWindow(workspaceID: workspaceID, trackedWindowID: trackedWindowID)) ?? false
            if focusedIterm {
                logBrowserFocus(
                    "workspace=\(workspaceID) path=iterm window=\(trackedWindowID) elapsed_ms=\(elapsedMS(since: focusStartedAt))")
                if (try? itermFocusPulseEnabled()) ?? SettingsKey.defaultItermFocusPulseEnabled {
                    let pulseColor = (try? itermFocusPulseColor()) ?? (r: 46, g: 41, b: 14)
                    let capturedIterm = iterm
                    Task.detached { try? capturedIterm.pulseBackground(windowID: trackedWindowID, pulseColor: pulseColor) }
                }
                return true
            }
        }
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

    private func focusItermTerminalWindow(workspaceID: String, trackedWindowID: Int) throws -> Bool {
        let runningProcess = try store.runningProcesses(workspaceID: workspaceID).first {
            $0.terminalApp == "iTerm2" && $0.windowID == trackedWindowID
        }
        let trackedWindow = try store.windows(workspaceID: workspaceID).first {
            $0.role == "terminal" && $0.app == "iTerm2" && $0.windowID == trackedWindowID
        }
        let fallbackMetadata = itermTerminalSessionMetadata(workspaceID: workspaceID, windowID: trackedWindowID)
        return try iterm.focusSessionOrTab(
            preferredSessionID: runningProcess?.itermSessionID ?? trackedWindow?.itermSessionID ?? fallbackMetadata?.sessionID,
            tabIndex: runningProcess?.itermTabIndex ?? trackedWindow?.itermTabIndex ?? fallbackMetadata?.tabIndex,
            windowID: trackedWindowID)
    }

    private func closeTrackedItermTerminalContainer(_ process: RunningProcessRecord) throws -> Bool {
        guard process.terminalApp == "iTerm2" else { return false }
        return (try? iterm.closeSessionOrTab(
            preferredSessionID: process.itermSessionID,
            tabIndex: process.itermTabIndex,
            windowID: process.windowID)) ?? false
    }

    private func closeTrackedItermTerminalWindow(workspaceID: String, windowID: Int) throws -> Bool {
        let trackedWindow = try store.windows(workspaceID: workspaceID).first {
            $0.role == "terminal" && $0.app == "iTerm2" && $0.windowID == windowID
        }
        if let preferredSessionID = trackedWindow?.itermSessionID,
            let closedSessionOrTab = try? iterm.closeSessionOrTab(
                preferredSessionID: preferredSessionID,
                tabIndex: trackedWindow?.itermTabIndex,
                windowID: windowID),
            closedSessionOrTab
        {
            return true
        }
        if let metadata = itermTerminalSessionMetadata(workspaceID: workspaceID, windowID: windowID) {
            let closedSessionOrTab = (try? iterm.closeSessionOrTab(
                preferredSessionID: metadata.sessionID,
                tabIndex: metadata.tabIndex,
                windowID: windowID)) ?? false
            if closedSessionOrTab { return true }
        }
        return false
    }

    private func setItermTerminalSessionMetadata(workspaceID: String, windowID: Int, sessionID: String?, tabIndex: Int?) {
        guard let sessionID, !sessionID.isEmpty else { return }
        let key = "\(workspaceID):\(windowID)"
        itermTerminalSessionLock.lock()
        itermTerminalSessionByWorkspaceAndWindowID[key] = ItermTerminalSessionMetadata(sessionID: sessionID, tabIndex: tabIndex)
        itermTerminalSessionLock.unlock()
    }

    private func itermTerminalSessionMetadata(workspaceID: String, windowID: Int) -> ItermTerminalSessionMetadata? {
        let key = "\(workspaceID):\(windowID)"
        itermTerminalSessionLock.lock()
        defer { itermTerminalSessionLock.unlock() }
        return itermTerminalSessionByWorkspaceAndWindowID[key]
    }

    private func clearItermTerminalSessionMetadata(workspaceID: String) {
        itermTerminalSessionLock.lock()
        itermTerminalSessionByWorkspaceAndWindowID = itermTerminalSessionByWorkspaceAndWindowID.filter { !$0.key.hasPrefix("\(workspaceID):") }
        itermTerminalSessionLock.unlock()
    }

    private func persistItermTerminalWindowMetadata(workspaceID: String, windowID: Int, sessionID: String?, tabIndex: Int?) throws {
        guard let sessionID, !sessionID.isEmpty else { return }
        let windows = try store.windows(workspaceID: workspaceID)
        guard let existing = windows.first(where: { $0.role == "terminal" && $0.app == "iTerm2" && $0.windowID == windowID }) else { return }
        let updated = WindowRecord(
            id: existing.id, workspaceID: existing.workspaceID, app: existing.app, title: existing.title, targetURL: existing.targetURL,
            windowID: existing.windowID, itermSessionID: sessionID, itermTabIndex: tabIndex,
            role: existing.role, orderIndex: existing.orderIndex, lastSeenAt: nowISO8601())
        try store.upsert(window: updated)
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
        fputs("muxy: browser focus \(message)\n", stderr)
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
                "muxy: browser scan workspace=\(workspaceID) tabs=\(tabs.count) matches=\(browserWindows.count) elapsed_ms=\(elapsedMS)\n",
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

    public func guiTooltipShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiTooltipShortcut) ?? SettingsKey.defaultGUITooltipShortcut
    }

    public func setGUITooltipShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiTooltipShortcut, value: raw) }

    public func itermFocusPulseColor() throws -> (r: Int, g: Int, b: Int) {
        let raw = (try? store.setting(key: SettingsKey.itermFocusPulseColor)) ?? SettingsKey.defaultItermFocusPulseColor
        let parts = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 else { return (r: 0, g: 0, b: 0) }
        return (r: parts[0], g: parts[1], b: parts[2])
    }

    public func setItermFocusPulseColor(r: Int, g: Int, b: Int) throws {
        let clamped = (r: max(0, min(255, r)), g: max(0, min(255, g)), b: max(0, min(255, b)))
        try store.setSetting(key: SettingsKey.itermFocusPulseColor, value: "\(clamped.r),\(clamped.g),\(clamped.b)")
    }

    public func itermFocusPulseEnabled() throws -> Bool {
        let raw = try? store.setting(key: SettingsKey.itermFocusPulseEnabled)
        guard let raw else { return SettingsKey.defaultItermFocusPulseEnabled }
        return raw != "0"
    }

    public func setItermFocusPulseEnabled(_ enabled: Bool) throws {
        try store.setSetting(key: SettingsKey.itermFocusPulseEnabled, value: enabled ? "1" : "0")
    }

    public func activeWorkspaceID() throws -> String? { try store.setting(key: "active_workspace_id") }

    public func setActiveWorkspace(id: String?) throws { try store.setSetting(key: "active_workspace_id", value: id) }

    private func normalizeDir(_ dir: String) throws -> ProjectRecord {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw MuxyError.invalidArgument(message: "Project directory not found: \(dir)")
        }
        let isGit = git.isRepo(path: dir)
        let branch = isGit ? git.defaultBranch(path: dir) : nil
        let name = URL(fileURLWithPath: dir).lastPathComponent
        return ProjectRecord(id: dir, name: name, dir: dir, isGitRepo: isGit, defaultBranch: branch)
    }

    private func ensureDefaultWorkspace(for project: ProjectRecord) throws {
        if let existing = try defaultWorkspace(projectID: project.id) {
            if existing.isArchived {
                let revived = WorkspaceRecord(
                    id: existing.id, projectID: project.id, name: existing.name, dir: existing.dir, dirname: existing.dirname,
                    branch: existing.branch, targetBranch: existing.targetBranch, isDefault: true, isArchived: false, isRunning: existing.isRunning,
                    lastLaunchedAt: existing.lastLaunchedAt)
                try store.upsert(workspace: revived)
            }
            return
        }
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, name: "default", dir: project.dir, dirname: nil, branch: project.defaultBranch,
            targetBranch: project.defaultBranch, isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        try seedWorkspaceSettings(project: project, workspace: workspace)
        let appConfig = try store.appConfig()
        let portDefinitions = try store.workspacePortDefinitions(workspaceID: workspace.id)
        _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, definitions: portDefinitions, range: appConfig.portRange)
    }

    private func ensureImportedGitDefaultWorkspace(for project: ProjectRecord, branch: String) throws {
        if let existing = try defaultWorkspace(projectID: project.id) {
            if existing.isArchived {
                let revived = WorkspaceRecord(
                    id: existing.id, projectID: project.id, name: existing.name, dir: existing.dir, dirname: existing.dirname,
                    branch: existing.branch, targetBranch: existing.targetBranch, isDefault: true, isArchived: false, isRunning: existing.isRunning,
                    lastLaunchedAt: existing.lastLaunchedAt)
                try store.upsert(workspace: revived)
            }
            return
        }

        let worktreeRoot = try worktreeRoot(project: project)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let workspaceDir = worktreeRoot.appendingPathComponent(branch, isDirectory: true).path
        try git.createWorktree(path: project.dir, worktreePath: workspaceDir, branch: branch, targetBranch: branch)

        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, name: branch, dir: workspaceDir, dirname: branch, branch: branch,
            targetBranch: branch, isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        try seedWorkspaceSettings(project: project, workspace: workspace)
        let appConfig = try store.appConfig()
        let portDefinitions = try store.workspacePortDefinitions(workspaceID: workspace.id)
        _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, definitions: portDefinitions, range: appConfig.portRange)
    }

    private func resolveWorkspace(id: String) throws -> (ProjectRecord, WorkspaceRecord) {
        guard let workspace = try store.workspace(id: id) else { throw MuxyError.invalidArgument(message: "Workspace not found.") }
        guard let project = try store.project(id: workspace.projectID) else { throw MuxyError.missingProject(dir: workspace.projectID) }
        return (project, workspace)
    }

    private func ensureWorkspaceSettings(for project: ProjectRecord) throws {
        let workspaces = try store.workspaces(projectID: project.id, includeArchived: true)
        for workspace in workspaces {
            let hasSettings = try store.workspaceSettingsExists(workspaceID: workspace.id)
            if !hasSettings { try seedWorkspaceSettings(project: project, workspace: workspace) }
        }
    }

    private func syncDefaultWorkspaceSettingsIfTemplateBased(project: ProjectRecord, previousRecord: ProjectRecord, updatedRecord: ProjectRecord)
        throws
    {
        guard let defaultWorkspace = try defaultWorkspace(projectID: project.id) else { return }

        let hasSettings = try store.workspaceSettingsExists(workspaceID: defaultWorkspace.id)
        if !hasSettings {
            try seedWorkspaceSettings(project: updatedRecord, workspace: defaultWorkspace)
            return
        }

        let currentSettings = WorkspaceSettings(
            stopScript: try store.workspaceStopScript(workspaceID: defaultWorkspace.id),
            ports: try store.workspacePortDefinitions(workspaceID: defaultWorkspace.id),
            processes: try store.workspaceProcesses(workspaceID: defaultWorkspace.id),
            statusChecks: try store.workspaceStatusChecks(workspaceID: defaultWorkspace.id),
            browserSessions: try store.workspaceBrowserSessions(workspaceID: defaultWorkspace.id))

        let previousTemplate = WorkspaceSettings(
            stopScript: previousRecord.stopScript, ports: previousRecord.ports, processes: previousRecord.processes,
            statusChecks: previousRecord.statusChecks, browserSessions: previousRecord.browserSessions)

        guard workspaceSettingsMatch(currentSettings, previousTemplate) else { return }

        try seedWorkspaceSettings(project: updatedRecord, workspace: defaultWorkspace)
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
                || left.timeout != right.timeout || left.onFail != right.onFail
            {
                return false
            }
        }
        return true
    }

    private func browserSessionsMatch(_ lhs: [BrowserSession], _ rhs: [BrowserSession]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) where left.name != right.name || left.url != right.url { return false }
        return true
    }

    private func seedWorkspaceSettings(project: ProjectRecord, workspace: WorkspaceRecord) throws {
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: project.stopScript)
        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: project.ports)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: project.processes)
        try store.setWorkspaceStatusChecks(workspaceID: workspace.id, checks: project.statusChecks)
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: project.browserSessions)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: nowISO8601())
    }

    public func workspaceSetupState(workspaceID: String) throws -> WorkspaceSetupState {
        _ = try resolveWorkspace(id: workspaceID)
        return try store.workspaceSetupState(workspaceID: workspaceID)
            ?? WorkspaceSetupState(status: .succeeded, errorMessage: nil, startedAt: nil, finishedAt: nil)
    }

    public func runWorkspaceSetup(workspaceID: String) throws {
        try withWorkspaceSetupLock(workspaceID: workspaceID) {
            let (project, workspace) = try resolveWorkspace(id: workspaceID)
            try runWorkspaceSetup(project: project, workspace: workspace)
        }
    }

    private func loadWorkspaceSettings(project: ProjectRecord, workspace: WorkspaceRecord) throws -> WorkspaceSettings? {
        let hasSettings = try store.workspaceSettingsExists(workspaceID: workspace.id)
        if !hasSettings { try seedWorkspaceSettings(project: project, workspace: workspace) }
        let stopScript = try store.workspaceStopScript(workspaceID: workspace.id)
        let ports = try store.workspacePortDefinitions(workspaceID: workspace.id)
        let processes = try store.workspaceProcesses(workspaceID: workspace.id)
        let statusChecks = try store.workspaceStatusChecks(workspaceID: workspace.id)
        let browserSessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        return WorkspaceSettings(
            stopScript: stopScript, ports: ports, processes: processes, statusChecks: statusChecks, browserSessions: browserSessions)
    }

    private func runScript(_ script: String, cwd: String) throws { _ = try Shell.run(["/bin/bash", "-lc", script], cwd: cwd) }

    private func initializeWorkspaceRuntime(project: ProjectRecord, workspace: WorkspaceRecord, runSetupScript: Bool) throws {
        let appConfig = try store.appConfig()
        let portDefinitions = try store.workspacePortDefinitions(workspaceID: workspace.id)
        _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, definitions: portDefinitions, range: appConfig.portRange)
        if runSetupScript {
            try runWorkspaceSetup(project: project, workspace: workspace)
        } else {
            try store.setWorkspaceSetupState(workspaceID: workspace.id, status: .pending, errorMessage: nil, startedAt: nil, finishedAt: nil)
        }
    }

    private func runWorkspaceSetup(project: ProjectRecord, workspace: WorkspaceRecord) throws {
        let setupScript = project.setupScript?.trimmingCharacters(in: .whitespacesAndNewlines)
        let startedAt = nowISO8601()
        try store.setWorkspaceSetupState(workspaceID: workspace.id, status: .running, errorMessage: nil, startedAt: startedAt, finishedAt: nil)
        guard let setupScript, !setupScript.isEmpty else {
            try store.setWorkspaceSetupState(
                workspaceID: workspace.id,
                status: .succeeded,
                errorMessage: nil,
                startedAt: startedAt,
                finishedAt: nowISO8601())
            return
        }
        do {
            let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
            let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
            try runScript(applyEnvVars(setupScript, env: env), cwd: workspace.dir)
            try store.setWorkspaceSetupState(
                workspaceID: workspace.id,
                status: .succeeded,
                errorMessage: nil,
                startedAt: startedAt,
                finishedAt: nowISO8601())
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try store.setWorkspaceSetupState(
                workspaceID: workspace.id,
                status: .failed,
                errorMessage: message,
                startedAt: startedAt,
                finishedAt: nowISO8601())
            throw error
        }
    }

    private func waitForWorkspaceSetupToComplete(workspaceID: String) throws {
        let waitStartedAt = currentDate()
        while true {
            let setupState = try workspaceSetupState(workspaceID: workspaceID)
            switch setupState.status {
            case .succeeded:
                return
            case .failed:
                let detail = setupState.errorMessage?.isEmpty == false ? setupState.errorMessage! : "unknown setup error"
                throw MuxyError.invalidArgument(message: "Workspace setup failed: \(detail)")
            case .pending, .running:
                if currentDate().timeIntervalSince(waitStartedAt) > 900 {
                    throw MuxyError.invalidArgument(
                        message:
                            "Timed out waiting for workspace setup to finish. Retry launch after setup completes or run mx workspace up --force-restart.")
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    private func withWorkspaceSetupLock<T>(workspaceID: String, operation: () throws -> T) throws -> T {
        workspaceSetupLock.lock()
        if workspaceSetupInFlight.contains(workspaceID) {
            workspaceSetupLock.unlock()
            throw MuxyError.invalidArgument(message: "Workspace setup is already in progress.")
        }
        workspaceSetupInFlight.insert(workspaceID)
        workspaceSetupLock.unlock()

        defer {
            workspaceSetupLock.lock()
            workspaceSetupInFlight.remove(workspaceID)
            workspaceSetupLock.unlock()
        }
        return try operation()
    }

    func buildWorkspaceEnv(project: ProjectRecord, workspace: WorkspaceRecord, namedPorts: [(port: Int, name: String)]) -> [String: String] {
        var env: [String: String] = [:]
        for namedPort in namedPorts {
            let key = namedPort.name.isEmpty ? "PORT\(env.count)" : namedPort.name
            env[key] = String(namedPort.port)
        }
        env["MUXY_WORKSPACE_DIR"] = workspace.dir
        env["MUXY_PROJECT_DIR"] = project.dir
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
            throw MuxyError.dependencyMissing(message: "iTerm2 is required to launch processes.")
        }

        for process in toStop {
            if let pid = resolvedRuntimePID(for: process) { terminateProcessGroup(pid: pid) }
            if process.terminalApp == "iTerm2" { _ = try? closeTrackedItermTerminalContainer(process) }
            try store.deleteRunningProcess(id: process.id)
        }

        for (desired, process) in toRelabel {
            let updated = RunningProcessRecord(
                id: process.id, workspaceID: workspace.id, templateName: desired.desiredKey, command: process.command,
                terminalApp: process.terminalApp, windowID: process.windowID, itermSessionID: process.itermSessionID,
                itermTabIndex: process.itermTabIndex, pid: process.pid, status: process.status, logPath: process.logPath,
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
                    terminalApp: "iTerm2", windowID: windowID, itermSessionID: process.itermSessionID,
                    itermTabIndex: process.itermTabIndex, pid: pid, status: .running, logPath: logFile, lastOutputAt: nil,
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
                    terminalApp: "iTerm2", windowID: resolvedWindowID, itermSessionID: window.sessionID, itermTabIndex: window.tabIndex, pid: pid,
                    status: .running, logPath: logFile, lastOutputAt: nil,
                    startedAt: nowISO8601(), exitedAt: nil)
                if let resolvedWindowID, resolvedWindowID > 0 {
                    setItermTerminalSessionMetadata(
                        workspaceID: workspace.id, windowID: resolvedWindowID, sessionID: window.sessionID, tabIndex: window.tabIndex)
                }
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
                terminalApp: "iTerm2", windowID: resolvedWindowID, itermSessionID: window.sessionID, itermTabIndex: window.tabIndex, pid: pid,
                status: .running, logPath: logFile, lastOutputAt: nil,
                startedAt: nowISO8601(), exitedAt: nil)
            if let resolvedWindowID, resolvedWindowID > 0 {
                setItermTerminalSessionMetadata(
                    workspaceID: workspace.id, windowID: resolvedWindowID, sessionID: window.sessionID, tabIndex: window.tabIndex)
            }
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
        guard chrome.isAvailable() else { throw MuxyError.dependencyMissing(message: "Google Chrome is required for browser sessions.") }
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

    @discardableResult
    private func pruneMissingWindows(workspaceID: String) throws -> Int {
        let existingIDs = Set(try yabai.listWindows().map(\.id))
        let windows = try store.windows(workspaceID: workspaceID)
        var pruned = 0
        for window in windows {
            guard let id = window.windowID else {
                try store.deleteWindow(id: window.id)
                pruned += 1
                continue
            }
            if !existingIDs.contains(id) {
                try store.deleteWindow(id: window.id)
                pruned += 1
            }
        }
        return pruned
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

    private func launchProcesses(workspace: WorkspaceRecord, templates: [ProcessTemplate], env: [String: String], background: Bool = false) throws {
        guard !templates.isEmpty else {
            try store.deleteRunningProcesses(workspaceID: workspace.id)
            return
        }
        guard iterm.isAvailable() else { throw MuxyError.dependencyMissing(message: "iTerm2 is required to launch processes.") }
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
            let window = try iterm.openWindowAndRun(command: command, background: background)
            let fallbackWindowID = try captureNewWindows(
                snapshot: snapshot, role: "terminal", appName: "iTerm2", workspaceID: workspace.id, orderOffset: 200
            ).first?.windowID

            let pid = try? Int(String(contentsOfFile: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))
            let running = RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: name, command: template.command, terminalApp: "iTerm2",
                windowID: window.id >= 0 ? window.id : fallbackWindowID, itermSessionID: window.sessionID, itermTabIndex: window.tabIndex, pid: pid,
                status: .running, logPath: logFile, lastOutputAt: nil,
                startedAt: nowISO8601(), exitedAt: nil)
            if let resolvedWindowID = (window.id >= 0 ? window.id : fallbackWindowID), resolvedWindowID > 0 {
                setItermTerminalSessionMetadata(
                    workspaceID: workspace.id, windowID: resolvedWindowID, sessionID: window.sessionID, tabIndex: window.tabIndex)
            }
            try store.upsert(runningProcess: running)
        }

    }

    private func ensureBrowserSessions(
        project: ProjectRecord, workspace: WorkspaceRecord, sessions: [BrowserSession], env: [String: String], extractOnAttach: Bool,
        background: Bool = false
    ) throws -> (windows: [WindowRecord], sessions: [BrowserSession])
    {
        _ = project
        guard !sessions.isEmpty else { return ([], []) }
        guard chrome.isAvailable() else { throw MuxyError.dependencyMissing(message: "Google Chrome is required for browser sessions.") }
        let resolvedSessions = resolveBrowserSessions(sessions, env: env)
        var attached: [WindowRecord] = []
        var refreshedSessions = sessions
        var seenKeys = Set<String>()
        for resolvedSession in resolvedSessions {
            var matches = try chrome.windowMatches(forURLPrefix: resolvedSession.prefix)
            let foundExistingTab = !matches.isEmpty
            if matches.isEmpty {
                _ = try chrome.openWindow(url: resolvedSession.prefix, background: background)
                matches = try chrome.windowMatches(forURLPrefix: resolvedSession.prefix)
            }
            if extractOnAttach, foundExistingTab,
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
        if let override = ProcessInfo.processInfo.environment["MUXY_RUNTIME_DIR"], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            dir = home.appendingPathComponent(".muxy", isDirectory: true).appendingPathComponent("runtime", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func shellCommand(base: String, cwd: String, env: [String: String], logFile: String, pidFile: String) -> String {
        let envExports = env.map { key, value in return "export \(key)=\"\(value)\"" }.sorted().joined(separator: "; ")
        let safeCwd = cwd
        let safeLog = logFile
        let safePid = pidFile
        
        // Write shell PID and keep shell alive with wait
        // isProcessAlive will check if any process in the group is alive
        let commands = [
            "cd \"\(safeCwd)\"",
            envExports.isEmpty ? nil : envExports,
            "echo $$ > \"\(safePid)\"",
            "\(base) 2>&1 | tee -a \"\(safeLog)\"",
        ].compactMap { $0 }
        let script = commands.joined(separator: "; ")
        let singleQuoted = script.replacing("'", with: "'\\''")
        return "bash -lc '\(singleQuoted)'"
    }

    func applyEnvVars(_ input: String, env: [String: String]) -> String {
        var output = input
        for (key, value) in env { output = output.replacingOccurrences(of: "$\(key)", with: value) }
        return output
    }

    /// Resolves `$VAR` references in a command string using the env vars for the given workspace.
    public func resolveEnvVars(in command: String, workspaceID: String) throws -> String {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspaceID)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        return applyEnvVars(command, env: env)
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
        if let pid = process.pid, pid > 0 {
            if isProcessAlive(pid: pid) { return pid }
            guard process.terminalApp == "iTerm2" else { return pid }
            guard let pidFile = try? processRuntimePaths(workspaceID: process.workspaceID, name: process.templateName).pidFile else {
                return pid
            }
            if let runtimePID = runtimePID(fromFile: pidFile), runtimePID > 0, isProcessAlive(pid: runtimePID) { return runtimePID }
            return pid
        }
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
        
        // First check if the specific PID is alive
        if Darwin.kill(pid_t(pid), 0) == 0 { return true }
        if errno == EPERM { return true }
        
        // If the PID is dead, check if any child processes are still alive
        // This handles cases where the shell exits but the actual command continues
        guard let output = try? Shell.runAndCapture(["pgrep", "-P", "\(pid)"]) else { return false }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
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
                throw MuxyError.invalidArgument(message: "Workspace directory name is already in use: \(requestedDirname)")
            }
            return requestedDirname
        }
        if let existingDirname, !existingDirname.isEmpty { return existingDirname }
        let used = try usedWorkspaceDirnames(project: project, excludingDirname: nil)
        if let available = MuxyOrchestrator.workspaceFoodNames.first(where: { !used.contains($0) }) { return available }
        throw MuxyError.invalidArgument(message: "No available workspace dirnames remain for project \(project.name).")
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
        guard !dirname.isEmpty else { throw MuxyError.invalidArgument(message: "Workspace directory name cannot be empty.") }
        if dirname.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            throw MuxyError.invalidArgument(message: "Workspace directory name cannot contain spaces.")
        }
        for scalar in dirname.unicodeScalars {
            guard scalar.isASCII else {
                throw MuxyError.invalidArgument(message: "Workspace directory name can only use letters, numbers, '-', and '_'.")
            }
            let value = scalar.value
            let isUppercaseLetter = value >= 65 && value <= 90
            let isLowercaseLetter = value >= 97 && value <= 122
            let isDigit = value >= 48 && value <= 57
            let isHyphen = value == 45
            let isUnderscore = value == 95
            guard isUppercaseLetter || isLowercaseLetter || isDigit || isHyphen || isUnderscore else {
                throw MuxyError.invalidArgument(message: "Workspace directory name can only use letters, numbers, '-', and '_'.")
            }
        }
    }

    private func isMissingWorktreeError(_ error: Error) -> Bool {
        guard case MuxyError.gitCommandFailed(let message) = error else { return false }
        let lowered = message.lowercased()
        return lowered.contains("not a working tree") || lowered.contains("does not exist") || lowered.contains("no such file or directory")
    }

    private func directoryExists(at path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isMissingDirectoryError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError { return true }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT { return true }
        let lowered = nsError.localizedDescription.lowercased()
        return lowered.contains("no such file") || lowered.contains("does not exist")
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

    private func repositoriesRootDirectory() -> URL {
        if let projectsRootDirectoryURL { return projectsRootDirectoryURL }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "muxy", directoryHint: .isDirectory).appending(path: "repos", directoryHint: .isDirectory)
    }

    private func legacyProjectsRootDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "muxy", directoryHint: .isDirectory).appending(path: "projects", directoryHint: .isDirectory)
    }

    private func workspaceRootDirectory() -> URL {
        if let workspacesRootDirectoryURL { return workspacesRootDirectoryURL }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "muxy", directoryHint: .isDirectory).appending(path: "workspaces", directoryHint: .isDirectory)
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
        guard project.isGitRepo, isManagedRepositoryDirectory(path: project.dir) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.dir, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        try FileManager.default.removeItem(atPath: project.dir)
    }

    private func isManagedRepositoryDirectory(path: String) -> Bool {
        if isPath(path, inside: repositoriesRootDirectory().path) { return true }
        if projectsRootDirectoryURL == nil, isPath(path, inside: legacyProjectsRootDirectory().path) { return true }
        return false
    }

    private func defaultWorkspace(projectID: String) throws -> WorkspaceRecord? {
        try store.workspaces(projectID: projectID, includeArchived: true).first(where: \.isDefault)
    }

    private func preferredImportedDefaultBranch(path: String) throws -> String {
        if git.branchExists(path: path, branch: "main") { return "main" }
        if git.branchExists(path: path, branch: "master") { return "master" }
        throw MuxyError.invalidArgument(message: "Imported git repository must contain a main or master branch.")
    }

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

    // MARK: - Agent Windows

    public func agentWindows(workspaceID: String) throws -> [AgentWindowRecord] { try store.agentWindows(workspaceID: workspaceID) }

    @discardableResult public func registerAgentWindow(
        workspaceID: String, provider: AgentProvider, label: String? = nil, itermSessionID: String? = nil, codexThreadID: String? = nil,
        yabaiWindowID: Int? = nil, status: AgentWindowStatus = .idle
    ) throws -> AgentWindowRecord {
        let now = nowISO8601()

        switch provider {
        case .codex:
            // Only one Codex agent record per workspace
            try store.deleteAgentWindowsByProvider(workspaceID: workspaceID, provider: .codex)
            let record = AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspaceID, provider: .codex, label: label, itermSessionID: nil, codexThreadID: codexThreadID,
                windowID: nil, yabaiWindowID: yabaiWindowID, status: status, createdAt: now, updatedAt: now)
            try store.upsertAgentWindow(record)
            return record

        case .iterm2:
            // Prune stale sessions before creating
            if let sessionID = itermSessionID {
                // Update existing record if same session
                if let existing = try store.agentWindow(workspaceID: workspaceID, itermSessionID: sessionID) {
                    let updated = AgentWindowRecord(
                        id: existing.id, workspaceID: existing.workspaceID, provider: existing.provider, label: label ?? existing.label,
                        itermSessionID: existing.itermSessionID, codexThreadID: existing.codexThreadID, windowID: existing.windowID,
                        yabaiWindowID: yabaiWindowID ?? existing.yabaiWindowID, status: status, createdAt: existing.createdAt, updatedAt: now)
                    try store.upsertAgentWindow(updated)
                    return updated
                }
            }
            // Prune stale iTerm2 sessions
            if let aliveIDs = try? iterm.listSessionIDs() {
                let existingRecords = try store.agentWindowsByProvider(workspaceID: workspaceID, provider: .iterm2)
                for stale in existingRecords {
                    guard let sid = stale.itermSessionID else {
                        try store.deleteAgentWindow(id: stale.id)
                        continue
                    }
                    if !aliveIDs.contains(sid) { try store.deleteAgentWindow(id: stale.id) }
                }
            }
            let record = AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspaceID, provider: .iterm2, label: label, itermSessionID: itermSessionID, codexThreadID: nil,
                windowID: nil, yabaiWindowID: yabaiWindowID, status: status, createdAt: now, updatedAt: now)
            try store.upsertAgentWindow(record)
            return record
        }
    }

    @discardableResult public func updateAgentWindowStatus(
        workspaceID: String, provider: AgentProvider, itermSessionID: String? = nil, codexThreadID: String? = nil, yabaiWindowID: Int? = nil,
        label: String? = nil, status: AgentWindowStatus
    ) throws -> AgentWindowRecord {
        let now = nowISO8601()
        // Find existing record
        var existing: AgentWindowRecord?
        if provider == .iterm2, let sessionID = itermSessionID {
            existing = try store.agentWindow(workspaceID: workspaceID, itermSessionID: sessionID)
        } else if provider == .codex, let threadID = codexThreadID {
            existing = try store.agentWindow(workspaceID: workspaceID, codexThreadID: threadID)
        } else if provider == .codex {
            existing = try store.agentWindowsByProvider(workspaceID: workspaceID, provider: .codex).first
        }
        if let existing {
            let updated = AgentWindowRecord(
                id: existing.id, workspaceID: existing.workspaceID, provider: existing.provider, label: label ?? existing.label,
                itermSessionID: existing.itermSessionID, codexThreadID: existing.codexThreadID, windowID: existing.windowID,
                yabaiWindowID: yabaiWindowID ?? existing.yabaiWindowID, status: status, createdAt: existing.createdAt, updatedAt: now)
            try store.upsertAgentWindow(updated)
            return updated
        }
        // Not found: register new
        return try registerAgentWindow(
            workspaceID: workspaceID, provider: provider, label: label, itermSessionID: itermSessionID, codexThreadID: codexThreadID,
            yabaiWindowID: yabaiWindowID, status: status)
    }

    public func focusAgentWindow(_ record: AgentWindowRecord) throws {
        switch record.provider {
        case .iterm2:
            let focused = (try? iterm.focusSessionOrTab(
                preferredSessionID: record.itermSessionID, tabIndex: nil, windowID: record.windowID)) ?? false
            if focused, let windowID = record.windowID ?? record.yabaiWindowID,
               (try? itermFocusPulseEnabled()) ?? SettingsKey.defaultItermFocusPulseEnabled {
                let color = (try? itermFocusPulseColor()) ?? (r: 46, g: 41, b: 14)
                try? iterm.pulseBackground(windowID: windowID, pulseColor: color)
            }
        case .codex:
            if let threadID = record.codexThreadID {
                try Shell.run(["open", "codex://threads/\(threadID)"])
            }
        }
    }

    private func safeFilename(_ raw: String) -> String {
        raw.map { char in
            if char.isLetter || char.isNumber { return char }
            return "_"
        }.reduce("") { $0 + String($1) }
    }

}
