import Darwin
import Foundation
@preconcurrency import UserNotifications
import appctl

public final class MuxyOrchestrator {
    public static let terminalTrackingIDEnvVar = "MUXY_TERMINAL_TRACKING_ID"
    public static let agentLabelEnvVar = "MUXY_AGENT_LABEL"

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

    private struct ManagedTerminalHandle {
        let fallbackWindowID: Int?
        let trackingIdentity: TerminalTrackingIdentity?
        let hookSessionID: String?
    }

    private enum WorkspaceNavigationCursor: Equatable {
        case terminal(String)
        case browserWindowURL(Int, String)
        case browserURL(String)
        case window(Int)
    }

    private enum WorkspaceNavigationTarget {
        case agent(AgentWindowRecord)
        case browser(WindowRecord)
        case process(RunningProcessRecord)
        case window(WindowRecord)
    }

    private enum FocusableWorkspaceTarget {
        case agent(AgentWindowRecord)
        case browserSession(targetURL: String)
        case configuredProcess(name: String)
        case process(RunningProcessRecord)
        case window(WindowRecord)
    }

    public let store: SQLiteStore
    private let git: GitClient
    private let yabai: YabaiAdapter
    private let iterm: Iterm2Adapter
    private let ghostty: GhosttyAdapter
    private let tmux: TmuxAdapter
    private let chrome: ChromeAdapter
    private let browserWindowScanDebounceInterval: TimeInterval
    private let currentDate: () -> Date
    private let projectsRootDirectoryURL: URL?
    private let workspacesRootDirectoryURL: URL?
    private let terminalAdaptersByHost: [TerminalHost: any TerminalAdapter]
    private let workspaceLifecycleLock = NSLock()
    private var workspaceLifecycleInFlight: Set<String> = []
    private let workspaceSetupLock = NSLock()
    private var workspaceSetupInFlight: Set<String> = []
    private let windowNavigationLock = NSLock()
    private var windowNavigationCursorByWorkspace: [String: WorkspaceNavigationCursor] = [:]
    private let browserScanCacheLock = NSLock()
    private var browserWindowScanCacheByWorkspace: [String: BrowserWindowScanCacheEntry] = [:]
    private let itermTerminalSessionLock = NSLock()
    private var itermTerminalSessionByWorkspaceAndWindowID: [String: ItermTerminalSessionMetadata] = [:]
    private let terminalFocusPulseController: TerminalFocusPulseControlling

    public init(
        store: SQLiteStore, projectsRootDirectory: URL? = nil, workspacesRootDirectory: URL? = nil, git: GitClient = .init(),
        yabai: YabaiAdapter = .init(), iterm: Iterm2Adapter = .init(), ghostty: GhosttyAdapter = .init(), tmux: TmuxAdapter = .init(),
        chrome: ChromeAdapter = .init(), browserWindowScanDebounceInterval: TimeInterval = PollingConstants.browserWindowScanDebounceInterval,
        terminalFocusPulseController: TerminalFocusPulseControlling = TerminalFocusPulseController(), currentDate: @escaping () -> Date = Date.init
    ) {
        self.store = store
        projectsRootDirectoryURL = projectsRootDirectory
        self.git = git
        self.yabai = yabai
        self.iterm = iterm
        self.ghostty = ghostty
        self.tmux = tmux
        self.chrome = chrome
        self.workspacesRootDirectoryURL = workspacesRootDirectory
        terminalAdaptersByHost = [.iterm2: iterm, .ghostty: ghostty]
        self.browserWindowScanDebounceInterval = browserWindowScanDebounceInterval
        self.terminalFocusPulseController = terminalFocusPulseController
        self.currentDate = currentDate
        if ProcessInfo.processInfo.environment["DEBUG"] == "1" { fputs("muxy: DEBUG=1 enabled (browser/cycle profiling active)\n", stderr) }
    }

    @discardableResult public func syncConfig() throws -> AppConfig { return try store.appConfig() }

    public func appConfig() throws -> AppConfig { try store.appConfig() }

    @discardableResult public func updatePortRange(_ range: PortRange) throws -> AppConfig {
        var config = try store.appConfig()
        config.portRange = range
        try store.setAppConfig(config)
        return config
    }

    @discardableResult public func updateTerminalHost(_ terminalHost: TerminalHost) throws -> AppConfig {
        var config = try store.appConfig()
        config.terminalHost = terminalHost
        try store.setAppConfig(config)
        return config
    }

    public func listProjects() throws -> [ProjectSummary] {
        return try store.projects().map {
            ProjectSummary(
                id: $0.id, name: $0.name, dir: $0.dir, isGitRepo: $0.isGitRepo, defaultBranch: $0.defaultBranch, isCollapsed: $0.isCollapsed)
        }
    }

    public func project(id: String) throws -> ProjectRecord? { try store.project(id: id) }

    public func setProjectCollapsed(projectID: String, isCollapsed: Bool) throws {
        try store.updateProjectCollapsed(id: projectID, isCollapsed: isCollapsed)
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
                id: $0.id, title: $0.title, branch: $0.branch, targetBranch: $0.targetBranch, dir: $0.dir, isRunning: $0.isRunning,
                isArchived: $0.isArchived, isHidden: $0.isHidden, isDefault: $0.isDefault, tooltip: $0.tooltip)
        }
    }

    public func suggestedWorkspaceName(projectID: String) throws -> String {
        guard let project = try store.project(id: projectID) else { throw MuxyError.missingProject(dir: projectID) }
        let existingNames = Set(try store.workspaces(projectID: project.id, includeArchived: true).map(\.title))
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

    private func isProtectedBranchName(_ branch: String) -> Bool {
        let normalized = branch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "main" || normalized == "master"
    }

    public func workspaceSettings(workspaceID: String) throws -> WorkspaceSettings? {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        return try loadWorkspaceSettings(project: project, workspace: workspace)
    }

    /// Returns the workspace's browser sessions with environment variables (e.g. $PORT) resolved to their
    /// actual values. The `url` field of each returned session is the fully-expanded prefix used for
    /// matching. Sessions whose URL is empty after expansion are omitted; duplicate resolved URLs are
    /// deduplicated (first occurrence wins, preserving order).
    public func resolvedWorkspaceBrowserSessions(workspaceID: String) throws -> [BrowserSession] {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let sessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        guard !sessions.isEmpty else { return [] }
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        return resolveBrowserSessions(sessions, env: env).map { resolved in
            BrowserSession(name: resolved.session.name, url: resolved.prefix, extractedWindow: resolved.session.extractedWindow)
        }
    }

    public func updateWorkspaceSettings(workspaceID: String, update: (inout WorkspaceSettings) -> Void) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard var existing = try loadWorkspaceSettings(project: project, workspace: workspace) else {
            throw MuxyError.missingProject(dir: project.dir)
        }
        let previousPorts = existing.ports
        let previousProcesses = existing.processes
        update(&existing)
        existing.ports = normalizePortDefinitionIDs(previous: previousPorts, updated: existing.ports)
        existing.processes = normalizeProcessTemplateIDs(previous: previousProcesses, updated: existing.processes)
        try validateWorkspaceFocusNames(
            workspaceID: workspace.id, processes: existing.processes, browserSessions: existing.browserSessions,
            agentLaunchers: existing.agentLaunchers, agentWindows: try store.agentWindows(workspaceID: workspace.id))
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: existing.stopScript)
        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: existing.ports)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: existing.processes)
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: existing.browserSessions)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: existing.agentLaunchers)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: nowISO8601())
        let appConfig = try store.appConfig()
        _ = try PortAllocator(store: store).syncPorts(workspaceID: workspace.id, definitions: existing.ports, range: appConfig.portRange)
    }

    public func updateRunningWorkspaceProcesses(workspaceID: String, processes: [ProcessTemplate], restartChangedCommands: Bool) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard var existing = try loadWorkspaceSettings(project: project, workspace: workspace) else {
            throw MuxyError.missingProject(dir: project.dir)
        }
        let normalizedProcesses = normalizeProcessTemplateIDs(previous: existing.processes, updated: processes)
        try validateWorkspaceFocusNames(
            workspaceID: workspace.id, processes: normalizedProcesses, browserSessions: existing.browserSessions,
            agentLaunchers: existing.agentLaunchers, agentWindows: try store.agentWindows(workspaceID: workspace.id))
        if workspace.isRunning {
            try applyRunningWorkspaceProcessEdits(
                project: project, workspace: workspace, previous: existing.processes, updated: normalizedProcesses,
                restartChangedCommands: restartChangedCommands)
        }
        existing.processes = normalizedProcesses
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: existing.processes)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: nowISO8601())
    }

    public func updateWorkspaceTooltip(workspaceID: String, tooltip: String?) throws {
        let (_, workspace) = try resolveWorkspace(id: workspaceID)
        try store.updateWorkspaceTooltip(id: workspace.id, tooltip: tooltip)
    }

    public func updateWorkspaceHidden(workspaceID: String, isHidden: Bool) throws {
        let (_, workspace) = try resolveWorkspace(id: workspaceID)
        guard workspace.isHidden != isHidden else { return }
        try store.updateWorkspaceHidden(id: workspace.id, isHidden: isHidden)
    }

    public func updateWorkspaceName(workspaceID: String, name: String) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw MuxyError.invalidArgument(message: "Workspace name is required.") }
        if trimmedName == workspace.title { return }
        if let existing = try store.workspace(projectID: workspace.projectID, name: trimmedName), existing.id != workspace.id {
            throw MuxyError.workspaceAlreadyExists(project: project.name, workspace: trimmedName)
        }
        try store.updateWorkspaceName(id: workspace.id, name: trimmedName)
    }

    public func updateWorkspaceMetadata(
        workspaceID: String, title: String? = nil, branch: String? = nil, directoryName: String? = nil, tooltip: String?? = nil
    ) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        var updatedTitle = workspace.title
        var updatedBranch = workspace.branch
        var updatedDirname = workspace.dirname
        var updatedTooltip = workspace.tooltip
        var didChange = false

        if let title {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { throw MuxyError.invalidArgument(message: "Workspace title is required.") }
            if trimmedTitle != workspace.title {
                if let existing = try store.workspace(projectID: workspace.projectID, name: trimmedTitle), existing.id != workspace.id {
                    throw MuxyError.workspaceAlreadyExists(project: project.name, workspace: trimmedTitle)
                }
                if workspace.isDefault {
                    // Default workspaces allow title overrides while default semantics remain on isDefault.
                    try store.updateWorkspaceTitle(id: workspace.id, title: trimmedTitle)
                } else {
                    updatedTitle = trimmedTitle
                }
                didChange = true
            }
        }

        if let branch {
            guard project.isGitRepo else { throw MuxyError.invalidArgument(message: "Branch can only be updated for git projects.") }
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
            guard project.isGitRepo else { throw MuxyError.invalidArgument(message: "Directory name can only be updated for git projects.") }
            let trimmedDirectoryName = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDirectoryName.isEmpty else { throw MuxyError.invalidArgument(message: "Workspace directory name cannot be empty.") }
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
            if updatedBranch != workspace.branch { try store.updateWorkspaceBranch(id: workspace.id, branch: updatedBranch) }
            if updatedDirname != workspace.dirname { try store.updateWorkspaceDirname(id: workspace.id, dirname: updatedDirname) }
            if updatedTooltip != workspace.tooltip { try store.updateWorkspaceTooltip(id: workspace.id, tooltip: updatedTooltip) }
            return
        }
        let updatedWorkspace = WorkspaceRecord(
            id: workspace.id, projectID: workspace.projectID, title: updatedTitle, dir: workspace.dir, dirname: updatedDirname, branch: updatedBranch,
            targetBranch: workspace.targetBranch, isDefault: workspace.isDefault, isArchived: workspace.isArchived, isHidden: workspace.isHidden,
            isRunning: workspace.isRunning, lastLaunchedAt: workspace.lastLaunchedAt, tooltip: updatedTooltip)
        try store.upsert(workspace: updatedWorkspace)
    }

    public func addProject(dir: String) throws -> ProjectRecord {
        let normalizedDir = normalizePath(dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedDir, isDirectory: &isDir), isDir.boolValue else {
            throw MuxyError.invalidArgument(message: "Project directory not found: \(normalizedDir)")
        }
        if try store.project(dir: normalizedDir) != nil { throw MuxyError.projectAlreadyExists(dir: normalizedDir) }
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

        if try store.project(dir: normalizedDestination) != nil { throw MuxyError.projectAlreadyExists(dir: normalizedDestination) }
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
        guard var record = try store.project(id: normalizedID) else { throw MuxyError.missingProject(dir: normalizedID) }
        let previousRecord = record
        update(&record)
        record = ProjectRecord(
            id: normalizedID, name: record.name, dir: record.dir, isGitRepo: record.isGitRepo, defaultBranch: record.defaultBranch,
            setupScript: record.setupScript, stopScript: record.stopScript, ports: record.ports, processes: record.processes,
            browserSessions: record.browserSessions, agentLaunchers: record.agentLaunchers)
        try validateUniqueConfiguredFocusNames(
            processes: record.processes, browserSessions: record.browserSessions, agentLaunchers: record.agentLaunchers)
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
        runSetupScript: Bool = true, allowRemoteBranchLookup: Bool = true
    ) throws -> WorkspaceRecord {
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
                guard let branchName = resolvedBranch else { throw MuxyError.invalidArgument(message: "Branch name is required for git projects.") }
                let dirname = try makeWorkspaceDirname(project: project, existingDirname: existing.dirname, requestedDirname: trimmedDirectoryName)
                revivedDirname = dirname
                let worktreeRoot = try worktreeRoot(project: project)
                try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
                revivedDir = worktreeRoot.appendingPathComponent(dirname, isDirectory: true).path
                if !FileManager.default.fileExists(atPath: revivedDir) {
                    try git.createWorktree(
                        path: project.dir, worktreePath: revivedDir, branch: branchName, targetBranch: resolvedTargetBranch,
                        allowRemoteBranchLookup: allowRemoteBranchLookup)
                }
                revivedBranch = branchName
            } else {
                revivedDir = project.dir
                revivedDirname = nil
                revivedBranch = nil
            }
            let revived = WorkspaceRecord(
                id: existing.id, projectID: project.id, title: trimmedName, dir: revivedDir, dirname: revivedDirname, branch: revivedBranch,
                targetBranch: existing.targetBranch ?? resolvedTargetBranch, isDefault: false, isArchived: false, isHidden: existing.isHidden,
                isRunning: false, lastLaunchedAt: nil)
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
                path: project.dir, worktreePath: workspaceDir, branch: branchName, targetBranch: resolvedTargetBranch,
                allowRemoteBranchLookup: allowRemoteBranchLookup)
            workspaceBranch = branchName
        } else {
            workspaceDir = project.dir
            workspaceDirname = nil
            workspaceBranch = nil
        }
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, title: trimmedName, dir: workspaceDir, dirname: workspaceDirname, branch: workspaceBranch,
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
        let gitCommonDirURL = URL(fileURLWithPath: gitCommonDir, relativeTo: URL(fileURLWithPath: normalizedWorktreePath)).standardized
        let gitRoot = gitCommonDirURL.deletingLastPathComponent().path
        let projectID = normalizePath(gitRoot)
        guard let project = try store.project(id: projectID) else {
            throw MuxyError.invalidArgument(
                message: "Project not found for git root: \(gitRoot). Add the project in the app before importing this workspace.")
        }
        if let existing = try store.workspace(dir: normalizedWorktreePath) {
            if existing.isArchived {
                throw MuxyError.invalidArgument(
                    message: "Workspace already exists but is archived: \(existing.title). Unarchive it or use a different worktree.")
            }
            throw MuxyError.invalidArgument(message: "Workspace already exists: \(existing.title)")
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
            id: UUID().uuidString, projectID: project.id, title: inferredName, dir: normalizedWorktreePath, dirname: dirname, branch: branch,
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        try seedWorkspaceSettings(project: project, workspace: workspace)
        try initializeWorkspaceRuntime(project: project, workspace: workspace, runSetupScript: true)
        return workspace
    }

    public func scanAndCreateWorkspacesFromWorktrees(projectID: String? = nil) throws -> [WorkspaceRecord] {
        let projects: [ProjectRecord]
        if let projectID {
            guard let project = try store.project(id: projectID) else { throw MuxyError.missingProject(dir: projectID) }
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
                guard isDiscoverableWorktreePath(project: project, path: normalizedPath) else { continue }
                discoverableWorktreeByPath[normalizedPath] = worktree
            }

            let existingWorkspaces = try store.workspaces(projectID: project.id, includeArchived: true)
            for workspace in existingWorkspaces {
                let normalizedWorkspacePath = normalizePath(workspace.dir)
                if let worktree = discoverableWorktreeByPath[normalizedWorkspacePath], workspace.branch != worktree.branchName {
                    let updatedWorkspace = WorkspaceRecord(
                        id: workspace.id, projectID: workspace.projectID, title: workspace.title, dir: workspace.dir, dirname: workspace.dirname,
                        branch: worktree.branchName, targetBranch: workspace.targetBranch, isDefault: workspace.isDefault,
                        isArchived: workspace.isArchived, isHidden: workspace.isHidden, isRunning: workspace.isRunning,
                        lastLaunchedAt: workspace.lastLaunchedAt, tooltip: workspace.tooltip)
                    try store.upsert(workspace: updatedWorkspace)
                }

                guard !workspace.isArchived, !workspace.isDefault else { continue }
                guard discoverableWorktreeByPath[normalizedWorkspacePath] == nil else { continue }
                try archiveWorkspaceBecauseWorktreeIsInvalid(workspaceID: workspace.id)
            }
            for worktree in worktrees {
                let normalizedPath = normalizePath(worktree.path)

                guard isDiscoverableWorktreePath(project: project, path: normalizedPath) else { continue }

                if try store.isIgnoredWorktree(path: normalizedPath) { continue }
                if (try store.workspace(dir: normalizedPath)) != nil { continue }
                guard let branchName = worktree.branchName else { continue }
                let workspace = WorkspaceRecord(
                    id: UUID().uuidString, projectID: project.id, title: branchName, dir: normalizedPath,
                    dirname: URL(fileURLWithPath: normalizedPath).lastPathComponent, branch: branchName, isDefault: false, isArchived: false,
                    isRunning: false, lastLaunchedAt: nil)
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
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        guard git.isRepo(path: path) else { return false }
        do {
            let gitCommonDirOutput = try git.runGitAndCapture(["-C", path, "rev-parse", "--git-common-dir"])
            let gitCommonDir = gitCommonDirOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let gitCommonDirURL = URL(fileURLWithPath: gitCommonDir, relativeTo: URL(fileURLWithPath: path)).standardized
            let gitRoot = normalizePath(gitCommonDirURL.deletingLastPathComponent().path)
            return gitRoot == project.id
        } catch { return false }
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
            try validateWorkspaceFocusNames(workspaceID: workspace.id)
            let hasTrackedRuntime = try hasTrackedRuntimeIndicators(workspaceID: workspace.id)
            if workspace.isRunning || hasTrackedRuntime {
                if restartIfRunning {
                    _ = try stopWorkspaceUnlocked(workspaceID: workspaceID)
                    try launchWorkspaceUnlocked(workspaceID: workspaceID, background: background)
                } else {
                    try refreshProcessStatuses(workspaceID: workspaceID, ignoreStartupGracePeriod: true)
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

        if let config {
            newWindows.append(contentsOf: try launchProcesses(workspace: workspace, templates: config.processes, env: env, background: background))
        }

        if let config {
            for launcher in config.agentLaunchers {
                let trimmedName = launcher.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { continue }
                _ = try launchAgentLauncher(workspaceID: workspace.id, name: trimmedName, background: background)
            }
            newWindows.append(
                contentsOf: try trackedTerminalWindowsForAgents(
                    workspaceID: workspace.id, agentWindows: try store.agentWindows(workspaceID: workspace.id)))
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
                id: window.id, workspaceID: window.workspaceID, app: window.app, name: window.name, detail: window.detail,
                targetURL: window.targetURL, windowID: window.windowID, terminalTrackingID: window.terminalTrackingID,
                terminalNativeID: window.terminalNativeID, itermTabIndex: window.itermTabIndex, tmuxWindowID: window.tmuxWindowID, role: window.role,
                orderIndex: index, lastSeenAt: window.lastSeenAt)
            index += 1
            try store.upsert(window: stored)
        }

        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: nowISO8601())
    }

    @discardableResult public func stopWorkspace(workspaceID: String) throws -> WorkspaceStopOutcome {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) { try stopWorkspaceUnlocked(workspaceID: workspaceID) }
    }

    private func stopWorkspaceUnlocked(workspaceID: String) throws -> WorkspaceStopOutcome {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let windows = try indexedWorkspaceWindows(workspaceID: workspace.id)
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        let processes = try store.runningProcesses(workspaceID: workspace.id)
        var skippedStopScriptBecauseWorkspaceDirectoryMissing = false
        for process in processes {
            if let pid = resolvedRuntimePID(for: process) { terminateProcessGroup(pid: pid) }
            if isManagedTerminalApp(process.terminalApp) { _ = try? closeTrackedItermTerminalContainer(process) }
            let sessionName = processTmuxSessionName(workspaceID: workspace.id, processName: process.templateName)
            if tmux.hasSession(named: sessionName) { try? tmux.killSession(named: sessionName) }
        }
        if let script = settings?.stopScript?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty {
            if directoryExists(at: workspace.dir) {
                do { try runScript(applyEnvVars(script, env: env), cwd: workspace.dir) } catch {
                    if isMissingDirectoryError(error) { skippedStopScriptBecauseWorkspaceDirectoryMissing = true } else { throw error }
                }
            } else {
                skippedStopScriptBecauseWorkspaceDirectoryMissing = true
            }
        }
        for window in windows {
            if window.role == "browser" {
                closeTrackedBrowserTab(window)
                continue
            }
            if window.role == "terminal", isManagedTerminalApp(window.app) {
                _ = try? closeTrackedItermTerminalWindow(window)
                continue
            }
            if let id = window.windowID { _ = try? yabai.closeWindow(id: id) }
        }
        for tmuxWindow in try tmuxWindows(workspaceID: workspace.id) { _ = try? tmux.killWindow(windowID: tmuxWindow.id) }
        try store.deleteRunningProcesses(workspaceID: workspace.id)
        try store.deleteWindows(workspaceID: workspace.id)
        try store.deleteAgentWindows(workspaceID: workspace.id)
        clearItermTerminalSessionMetadata(workspaceID: workspace.id)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: false, launchedAt: workspace.lastLaunchedAt)
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
        let agentWindows = try store.agentWindows(workspaceID: workspaceID)
        return !trackedProcesses.isEmpty || !trackedWindows.isEmpty || !agentWindows.isEmpty
    }

    public func workspaceRuntimeStatus(workspaceID: String) throws -> WorkspaceRuntimeStatus {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let lifecycleState = WorkspaceLifecycleState(isRunning: workspace.isRunning)
        let runningProcesses = try store.runningProcesses(workspaceID: workspaceID)
        let trackedWindows = try store.windows(workspaceID: workspaceID)
        let agentWindows = try store.agentWindows(workspaceID: workspaceID)
        let hasTrackedRuntimeIndicators = !runningProcesses.isEmpty || !trackedWindows.isEmpty || !agentWindows.isEmpty

        let runningProcessCount = runningProcesses.filter { $0.status == .running }.count
        let exitedProcessCount = runningProcesses.filter { $0.status == .exited }.count
        let waitingAgentWindowCount = agentWindows.filter { $0.status == .waiting }.count

        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        let expectedProcessKeys = (settings?.processes ?? []).map { configuredProcessMatchKey(name: $0.name) }
        let trackedProcessKeys = runningProcesses.map { runningProcessMatchKey(name: $0.templateName) }
        let missingConfiguredProcessCount = missingRuntimeRecordCount(expectedKeys: expectedProcessKeys, actualKeys: trackedProcessKeys)

        let expectedBrowserTargets = Set(try resolvedWorkspaceBrowserSessions(workspaceID: workspaceID).compactMap(\.url).filter { !$0.isEmpty })
        let trackedBrowserTargets = Set(trackedWindows.filter { $0.role == "browser" }.compactMap(\.targetURL).filter { !$0.isEmpty })
        let missingConfiguredBrowserSessionCount = expectedBrowserTargets.subtracting(trackedBrowserTargets).count

        let expectsManagedRuntime = !expectedProcessKeys.isEmpty
        let runtimeHealth: WorkspaceRuntimeHealth =
            switch lifecycleState {
            case .stopped: hasTrackedRuntimeIndicators ? .partial : .healthy
            case .running:
                if !hasTrackedRuntimeIndicators {
                    expectsManagedRuntime ? .missing : .healthy
                } else if exitedProcessCount > 0 || waitingAgentWindowCount > 0 || missingConfiguredProcessCount > 0 {
                    .partial
                } else {
                    .healthy
                }
            }

        return WorkspaceRuntimeStatus(
            workspaceID: workspaceID, lifecycleState: lifecycleState, runtimeHealth: runtimeHealth,
            hasTrackedRuntimeIndicators: hasTrackedRuntimeIndicators, runningProcessCount: runningProcessCount,
            exitedProcessCount: exitedProcessCount, waitingAgentWindowCount: waitingAgentWindowCount,
            missingConfiguredProcessCount: missingConfiguredProcessCount, missingConfiguredBrowserSessionCount: missingConfiguredBrowserSessionCount)
    }

    // Configured-process matching uses the raw configured name directly.
    private func configuredProcessMatchKey(name: String?) -> String { name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    private func runningProcessMatchKey(name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func missingRuntimeRecordCount(expectedKeys: [String], actualKeys: [String]) -> Int {
        var actualCounts: [String: Int] = [:]
        for key in actualKeys { actualCounts[key, default: 0] += 1 }

        var missingCount = 0
        for key in expectedKeys {
            if let currentCount = actualCounts[key], currentCount > 0 { actualCounts[key] = currentCount - 1 } else { missingCount += 1 }
        }
        return missingCount
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
        for project in allProjects {
            let workspaces = try store.workspaces(projectID: project.id, includeArchived: false)
            for workspace in workspaces {
                if try refreshProcessStatuses(workspaceID: workspace.id, project: project) { didUpdate = true }
                if try syncTrackedTmuxRuntime(workspaceID: workspace.id) { didUpdate = true }
                // iTerm exposes live session identity directly, so it can prune stale ad-hoc
                // agent rows before the generic window-reconciliation pass notices a closed window.
                if try pruneStaleItermAgentWindows(workspaceID: workspace.id) > 0 { didUpdate = true }
            }
        }
        return didUpdate
    }

    @discardableResult private func refreshProcessStatuses(workspaceID: String, ignoreStartupGracePeriod: Bool = false) throws -> Bool {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        return try refreshProcessStatuses(
            workspaceID: workspaceID, project: project, workspace: workspace, ignoreStartupGracePeriod: ignoreStartupGracePeriod)
    }

    @discardableResult private func refreshProcessStatuses(
        workspaceID: String, project: ProjectRecord, workspace: WorkspaceRecord? = nil, ignoreStartupGracePeriod: Bool = false
    ) throws -> Bool {
        let workspace = try workspace ?? resolveWorkspace(id: workspaceID).1
        let processes = try store.runningProcesses(workspaceID: workspace.id)
        let now = currentDate()
        let formatter = ISO8601DateFormatter()
        var didUpdate = false
        for process in processes where process.status == .running {
            if !ignoreStartupGracePeriod, let startedAtStr = process.startedAt, let startedAt = formatter.date(from: startedAtStr),
                now.timeIntervalSince(startedAt) < 10.0
            {
                continue
            }
            guard let pid = resolvedRuntimePID(for: process) else { continue }
            if !isProcessAlive(pid: pid) {
                let updatedProcess = RunningProcessRecord(
                    id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                    terminalApp: process.terminalApp, windowID: process.windowID, terminalTrackingID: process.terminalTrackingID,
                    terminalNativeID: process.terminalNativeID, itermTabIndex: process.itermTabIndex, tmuxWindowID: process.tmuxWindowID,
                    pid: process.pid, status: .exited, logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt,
                    exitedAt: nowISO8601())
                try store.upsert(runningProcess: updatedProcess)
                didUpdate = true
                try handleProcessExit(workspaceID: workspace.id, process: updatedProcess, project: project, workspace: workspace)
            }
        }
        return didUpdate
    }
    private func deliverNotification(title: String, body: String, subtitle: String? = nil) {
        guard NSClassFromString("XCTest") == nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let subtitle { content.subtitle = subtitle }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                center.add(request) { error in if let error { fputs("muxy: Failed to deliver notification: \(error.localizedDescription)\n", stderr) }
                }
            }
        }
    }
    private func handleProcessExit(workspaceID: String, process: RunningProcessRecord, project: ProjectRecord, workspace: WorkspaceRecord) throws {
        // Find the process template to get the on-exit behavior
        guard let config = try loadWorkspaceSettings(project: project, workspace: workspace) else { return }
        guard let processTemplate = config.processes.first(where: { ($0.name ?? $0.command) == process.templateName }) else { return }
        switch processTemplate.onExit {
        case .none:
            // Do nothing - just log the exit
            break
        case .notify: deliverNotification(title: "Process Exited", body: "Process '\(process.templateName)' has exited", subtitle: nil)
        case .restart:
            // Restart the process
            fputs("muxy: Restarting process '\(process.templateName)' due to exit\n", stderr)
            deliverNotification(title: "Process Restarting", body: "Process '\(process.templateName)' is being restarted", subtitle: nil)
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
        let terminalHost = try terminalHost(for: process.terminalApp) ?? configuredTerminalHost()
        guard terminalAdapterAvailable(terminalHost) else {
            throw MuxyError.dependencyMissing(message: missingTerminalDependencyMessage(for: terminalHost, operation: "launch processes"))
        }
        guard tmux.isAvailable() else { throw MuxyError.dependencyMissing(message: "tmux is required to launch processes.") }
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspaceID)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        _ = terminateProcessForRestart(process)
        _ = try? closeTrackedItermTerminalContainer(process)
        guard let command = parseDirectProcessCommand(process.command, env: env) else {
            throw MuxyError.invalidArgument(message: invalidDirectProcessCommandMessage(process.command, env: env))
        }
        let snapshot = bestEffortYabaiWindowSnapshot()
        let terminalHandle = try launchProcessInTmux(
            workspace: workspace, processName: process.templateName, rawCommand: process.command, command: command, env: env,
            terminalHost: terminalHost, background: background, replaceExistingSession: true)
        let capturedWindowID =
            bestEffortCaptureNewAppWindowID(snapshot: snapshot, appName: terminalAppName(for: terminalHost)) ?? terminalHandle.fallbackWindowID
            ?? process.windowID
        let tmuxWindow = try currentTmuxWindowInfo(workspaceID: workspace.id, processName: process.templateName)
        let newPID = tmuxWindow?.panePID
        let hookSessionID = storedTerminalHookSessionID(terminalHost: terminalHost, handle: terminalHandle)
        let terminalNativeID = storedTerminalNativeID(terminalHost: terminalHost, handle: terminalHandle)
        let restartedProcess = RunningProcessRecord(
            id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
            terminalApp: terminalAppName(for: terminalHost), windowID: capturedWindowID, terminalTrackingID: hookSessionID,
            terminalNativeID: terminalNativeID, itermTabIndex: nil, tmuxWindowID: tmuxWindow?.id, pid: newPID, status: .running, logPath: nil,
            lastOutputAt: nil, startedAt: nowISO8601(), exitedAt: nil)
        try store.upsert(runningProcess: restartedProcess)
        let existingWindows = try store.windows(workspaceID: workspace.id)
        let existingWindow =
            existingWindows.first(where: { $0.role == "terminal" && $0.windowID == process.windowID })
            ?? existingWindows.first(where: { $0.role == "terminal" && $0.id == process.id })
        let restoredWindow = WindowRecord(
            id: existingWindow?.id ?? process.id, workspaceID: workspace.id, app: terminalAppName(for: terminalHost), name: process.templateName,
            detail: process.command, targetURL: nil, windowID: capturedWindowID, terminalTrackingID: hookSessionID,
            terminalNativeID: terminalNativeID, itermTabIndex: nil, tmuxWindowID: tmuxWindow?.id, role: "terminal",
            orderIndex: existingWindow?.orderIndex ?? Self.nextWindowOrderIndex(existing: existingWindows, role: "terminal", orderOffset: 200),
            lastSeenAt: nowISO8601())
        try store.upsert(window: restoredWindow)
    }

    private func terminateProcessForRestart(_ process: RunningProcessRecord) -> Bool {
        guard let pid = resolvedRuntimePID(for: process) else { return true }
        terminateProcessGroup(pid: pid)
        waitForProcessExit(pid: pid, timeout: 10.0)
        guard isProcessAlive(pid: pid) else { return true }
        fputs("muxy: Process '\(process.templateName)' with pid \(pid) did not exit in time; restart will use a new tmux window\n", stderr)
        return false
    }

    public func windows(workspaceID: String) throws -> [WindowRecord] { try indexedWorkspaceWindows(workspaceID: workspaceID) }

    public struct RefreshResult: Sendable {
        public let didMutateDB: Bool
        public let trackedWindowCounts: [String: Int]
    }

    @discardableResult public func refreshWorkspaceWindows(workspaceID: String) throws -> Bool {
        let syncedTmuxRuntime = try syncTrackedTmuxRuntime(workspaceID: workspaceID)
        _ = try indexedWorkspaceWindows(workspaceID: workspaceID)
        let refreshedTerminalTitles = try refreshUnmanagedTerminalWindowTitles(workspaceID: workspaceID)
        let pruned = try pruneMissingWindows(workspaceID: workspaceID)
        return syncedTmuxRuntime || refreshedTerminalTitles > 0 || pruned > 0
    }

    @discardableResult private func refreshUnmanagedTerminalWindowTitles(workspaceID: String) throws -> Int {
        let windows = try store.windows(workspaceID: workspaceID)
        let processWindowIDs = Set(try store.runningProcesses(workspaceID: workspaceID).compactMap(\.windowID))
        let terminalWindowsToRefresh = windows.filter { window in
            if window.tmuxWindowID != nil { return false }
            guard window.role == "terminal", let windowID = window.windowID else { return false }
            return !processWindowIDs.contains(windowID)
        }
        guard !terminalWindowsToRefresh.isEmpty else { return 0 }

        let liveWindowsByID = Dictionary(uniqueKeysWithValues: try yabai.listWindows().map { ($0.id, $0) })
        var refreshedCount = 0
        for window in terminalWindowsToRefresh {
            guard let windowID = window.windowID, let liveWindow = liveWindowsByID[windowID] else { continue }
            let refreshedName = window.name
            let refreshedDetail = liveWindow.title
            let refreshedApp = liveWindow.app
            guard window.name != refreshedName || window.detail != refreshedDetail || window.app != refreshedApp else { continue }
            let refreshedWindow = WindowRecord(
                id: window.id, workspaceID: window.workspaceID, app: refreshedApp, name: refreshedName, detail: refreshedDetail,
                targetURL: window.targetURL, windowID: windowID, terminalTrackingID: window.terminalTrackingID,
                terminalNativeID: window.terminalNativeID, itermTabIndex: window.itermTabIndex, tmuxWindowID: window.tmuxWindowID, role: window.role,
                orderIndex: window.orderIndex, lastSeenAt: window.lastSeenAt)
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
                let tracked = try indexedWorkspaceWindows(workspaceID: workspace.id)
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
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isArchived else { throw MuxyError.invalidArgument(message: "Workspace is archived.") }
        let terminalHost = try configuredTerminalHost()
        guard terminalAdapterAvailable(terminalHost) else {
            throw MuxyError.dependencyMissing(message: missingTerminalDependencyMessage(for: terminalHost, operation: "open terminal windows"))
        }
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspaceID)
        let env = terminalLaunchEnvironment(
            base: buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts), terminalHost: terminalHost)
        let snapshot = bestEffortYabaiWindowSnapshot()
        let terminalHandle = try openManagedTerminalWindow(
            terminalHost: terminalHost, command: interactiveShellCommand(cwd: workspace.dir), cwd: workspace.dir, environment: env, background: false)
        let capturedWindowID =
            bestEffortCaptureNewAppWindowID(snapshot: snapshot, appName: terminalAppName(for: terminalHost)) ?? terminalHandle.fallbackWindowID
        let existing = try store.windows(workspaceID: workspace.id)
        let nextOrder = Self.nextWindowOrderIndex(existing: existing, role: "terminal", orderOffset: 200)
        let generatedTitle = try generatedAdHocTerminalWindowName(workspaceID: workspace.id)
        let hookSessionID = storedTerminalHookSessionID(terminalHost: terminalHost, handle: terminalHandle)
        let terminalNativeID = storedTerminalNativeID(terminalHost: terminalHost, handle: terminalHandle)
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: terminalAppName(for: terminalHost), name: generatedTitle, detail: nil,
                targetURL: nil, windowID: capturedWindowID, terminalTrackingID: hookSessionID, terminalNativeID: terminalNativeID, itermTabIndex: nil,
                tmuxWindowID: nil, role: "terminal", orderIndex: nextOrder, lastSeenAt: nowISO8601()))
        if !workspace.isRunning {
            let launchedAt = workspace.lastLaunchedAt ?? nowISO8601()
            try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: launchedAt)
        }
    }

    public func focusWorkspace(workspaceID: String) throws {
        let windows = try indexedWorkspaceWindows(workspaceID: workspaceID)
        var focused = false
        for window in windows {
            let ok = focusTrackedWindow(window, workspaceID: workspaceID)
            if ok {
                focused = true
                rememberNavigationTarget(navigationTarget(for: window), workspaceID: workspaceID)
                break
            }
        }
        if focused { try setActiveWorkspace(id: workspaceID) }
    }

    public func workspaceFocusableWindowNames(workspaceID: String) throws -> [String] {
        _ = try resolveWorkspace(id: workspaceID)
        return try focusableWorkspaceTargets(workspaceID: workspaceID).map(\.name)
    }

    public func focusWorkspaceWindow(workspaceID: String, index: Int) throws {
        guard index > 0 else { return }
        let focusStartedAt = currentDate()
        let loadWindowsStartedAt = currentDate()
        let windows = try indexedWorkspaceWindows(workspaceID: workspaceID)
        logCycleProfile(
            "workspace=\(workspaceID) stage=direct_load_windows index=\(index) count=\(windows.count) elapsed_ms=\(elapsedMS(since: loadWindowsStartedAt))"
        )
        guard index <= windows.count else { return }
        let targetIndex = index - 1
        let focusTargetStartedAt = currentDate()
        let ok = try focusTrackedWindowOrRecoverBrowserWindow(windows[targetIndex], workspaceID: workspaceID)
        logCycleProfile(
            "workspace=\(workspaceID) stage=direct_focus_target index=\(index) target=\(navigationTargetDebugName(navigationTarget(for: windows[targetIndex]))) success=\(ok ? 1 : 0) elapsed_ms=\(elapsedMS(since: focusTargetStartedAt))"
        )
        guard ok else { throw missingTrackedWindowError(for: windows[targetIndex], workspaceID: workspaceID) }
        if ok {
            rememberNavigationTarget(navigationTarget(for: windows[targetIndex]), workspaceID: workspaceID)
            try setActiveWorkspace(id: workspaceID)
        }
        logCycleProfile(
            "workspace=\(workspaceID) stage=direct_focus_total index=\(index) target=\(navigationTargetDebugName(navigationTarget(for: windows[targetIndex]))) success=\(ok ? 1 : 0) elapsed_ms=\(elapsedMS(since: focusStartedAt))"
        )
        logPerfMetric(
            "direct_window_focus", workspaceID: workspaceID, target: navigationTargetDebugName(navigationTarget(for: windows[targetIndex])),
            detail: "index=\(index)", elapsedMS: elapsedMS(since: focusStartedAt), success: ok)
    }

    public func focusWorkspaceWindow(workspaceID: String, name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw MuxyError.invalidArgument(message: "Window name is required.") }
        let focusStartedAt = currentDate()
        let targets = try focusableWorkspaceTargets(workspaceID: workspaceID)
        guard let match = targets.first(where: { normalizedFocusName($0.name) == normalizedFocusName(trimmedName) }) else {
            throw MuxyError.invalidArgument(message: missingFocusNameMessage(name: trimmedName, availableNames: targets.map(\.name)))
        }

        switch match.target {
        case .agent(let record):
            let focused = try focusAgentWindowRecord(record)
            guard focused else { throw missingTrackedAgentError(record) }
            rememberNavigationTarget(.agent(record), workspaceID: workspaceID)
        case .browserSession(let targetURL): try focusWorkspaceBrowserSession(workspaceID: workspaceID, targetURL: targetURL)
        case .configuredProcess(let processName):
            throw MuxyError.invalidArgument(message: "Process window '\(processName)' is not currently running.")
        case .process(let process):
            let focused = try focusWorkspaceProcessRecord(process, workspaceID: workspaceID)
            guard focused else { throw missingTrackedProcessError(process, workspaceID: workspaceID) }
            rememberNavigationTarget(.process(process), workspaceID: workspaceID)
        case .window(let window):
            let focused = try focusTrackedWindowOrRecoverBrowserWindow(window, workspaceID: workspaceID)
            guard focused else { throw missingTrackedWindowError(for: window, workspaceID: workspaceID) }
            rememberNavigationTarget(navigationTarget(for: window), workspaceID: workspaceID)
        }

        try setActiveWorkspace(id: workspaceID)
        logCycleProfile(
            "workspace=\(workspaceID) stage=direct_focus_total name=\(trimmedName) success=1 elapsed_ms=\(elapsedMS(since: focusStartedAt))")
        logPerfMetric("named_window_focus", workspaceID: workspaceID, target: trimmedName, elapsedMS: elapsedMS(since: focusStartedAt), success: true)
    }

    public func focusWorkspaceBrowserSession(workspaceID: String, targetURL: String) throws {
        let focusStartedAt = currentDate()
        let windows = try indexedWorkspaceWindows(workspaceID: workspaceID)
        if let window = windows.first(where: { $0.role == "browser" && $0.targetURL == targetURL }) {
            let focused = try focusTrackedWindowOrRecoverBrowserWindow(window, workspaceID: workspaceID)
            guard focused else { throw missingTrackedWindowError(for: window, workspaceID: workspaceID) }
            rememberNavigationTarget(navigationTarget(for: window), workspaceID: workspaceID)
            try markWorkspaceRunningIfNeeded(workspaceID: workspaceID)
            try setActiveWorkspace(id: workspaceID)
            logPerfMetric(
                "browser_focus", workspaceID: workspaceID, target: targetURL, detail: "recovered=0", elapsedMS: elapsedMS(since: focusStartedAt),
                success: true)
            return
        }

        try recoverMissingBrowserSession(workspaceID: workspaceID, targetURL: targetURL)
        if let recoveredWindow = try indexedWorkspaceWindows(workspaceID: workspaceID).first(where: {
            $0.role == "browser" && $0.targetURL == targetURL
        }) {
            rememberNavigationTarget(navigationTarget(for: recoveredWindow), workspaceID: workspaceID)
        }
        try setActiveWorkspace(id: workspaceID)
        logPerfMetric(
            "browser_focus", workspaceID: workspaceID, target: targetURL, detail: "recovered=1", elapsedMS: elapsedMS(since: focusStartedAt),
            success: true)
    }

    public func focusWorkspaceProcess(workspaceID: String, processID: String) throws {
        let focusStartedAt = currentDate()
        guard let process = try store.runningProcesses(workspaceID: workspaceID).first(where: { $0.id == processID }) else { return }
        let focused = try focusWorkspaceProcessRecord(process, workspaceID: workspaceID)
        guard focused else { throw missingTrackedProcessError(process, workspaceID: workspaceID) }
        rememberNavigationTarget(.process(process), workspaceID: workspaceID)
        try markWorkspaceRunningIfNeeded(workspaceID: workspaceID)
        try setActiveWorkspace(id: workspaceID)
        logPerfMetric(
            "process_focus", workspaceID: workspaceID, target: process.templateName, elapsedMS: elapsedMS(since: focusStartedAt), success: true)
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
        let cycleStartedAt = currentDate()
        let direction = delta > 0 ? "next" : "previous"
        let targetsStartedAt = currentDate()
        let targets = try workspaceNavigationTargets(workspaceID: workspaceID, forCycling: true)
        logCycleProfile(
            "workspace=\(workspaceID) stage=targets direction=\(direction) count=\(targets.count) elapsed_ms=\(elapsedMS(since: targetsStartedAt))")
        guard !targets.isEmpty else { return }
        let currentIndexStartedAt = currentDate()
        let currentIndex =
            try currentFocusedNavigationTargetIndex(targets: targets, workspaceID: workspaceID)
            ?? windowNavigationCursor(workspaceID: workspaceID).flatMap { navigationTargetIndex(cursor: $0, targets: targets) }
        logCycleProfile(
            "workspace=\(workspaceID) stage=current_target direction=\(direction) resolved_index=\(currentIndex.map(String.init) ?? "nil") elapsed_ms=\(elapsedMS(since: currentIndexStartedAt))"
        )
        let targetIndex: Int
        if let currentIndex {
            targetIndex = (currentIndex + delta + targets.count) % targets.count
        } else if delta > 0 {
            targetIndex = 0
        } else {
            targetIndex = targets.count - 1
        }
        var resolvedTargetIndex = targetIndex
        var ok = false
        for attempt in 0..<targets.count {
            let candidateIndex = (targetIndex + (attempt * delta) + (targets.count * 4)) % targets.count
            let focusTargetStartedAt = currentDate()
            let candidateFocused = try focusNavigationTarget(targets[candidateIndex], workspaceID: workspaceID)
            logCycleProfile(
                "workspace=\(workspaceID) stage=focus_target direction=\(direction) attempt=\(attempt) index=\(candidateIndex) target=\(navigationTargetDebugName(targets[candidateIndex])) success=\(candidateFocused ? "1" : "0") elapsed_ms=\(elapsedMS(since: focusTargetStartedAt))"
            )
            guard candidateFocused else { continue }
            resolvedTargetIndex = candidateIndex
            ok = true
            break
        }
        if ok {
            let activeWorkspaceStartedAt = currentDate()
            setWindowNavigationCursor(navigationCursor(for: targets[resolvedTargetIndex]), workspaceID: workspaceID)
            try setActiveWorkspace(id: workspaceID)
            logCycleProfile(
                "workspace=\(workspaceID) stage=set_active direction=\(direction) elapsed_ms=\(elapsedMS(since: activeWorkspaceStartedAt))")
        }
        logCycleProfile(
            "workspace=\(workspaceID) direction=\(direction) total_ms=\(elapsedMS(since: cycleStartedAt)) target=\(navigationTargetDebugName(targets[resolvedTargetIndex])) success=\(ok ? "1" : "0")"
        )
        logPerfMetric(
            "window_cycle", workspaceID: workspaceID, target: navigationTargetDebugName(targets[resolvedTargetIndex]),
            detail: "direction=\(direction)", elapsedMS: elapsedMS(since: cycleStartedAt), success: ok)
    }

    private func currentFocusedNavigationTargetIndex(targets: [WorkspaceNavigationTarget], workspaceID: String) throws -> Int? {
        let resolutionStartedAt = currentDate()
        let focusedWindowStartedAt = currentDate()
        guard let focused = try yabai.focusedWindow() else {
            logCycleProfile("workspace=\(workspaceID) stage=current_target_resolved path=none elapsed_ms=\(elapsedMS(since: resolutionStartedAt))")
            return nil
        }
        logCycleProfile(
            "workspace=\(workspaceID) stage=focused_window app=\(focused.app) window=\(focused.id) elapsed_ms=\(elapsedMS(since: focusedWindowStartedAt))"
        )
        let windowMatches = targets.enumerated().filter { navigationTargetWindowID($0.element) == focused.id }
        if let cursor = windowNavigationCursor(workspaceID: workspaceID),
            let match = windowMatches.first(where: { navigationCursor(for: $0.element) == cursor })
        {
            logCycleProfile(
                "workspace=\(workspaceID) stage=current_target_resolved path=cursor index=\(match.offset) elapsed_ms=\(elapsedMS(since: resolutionStartedAt))"
            )
            return match.offset
        }
        if let match = windowMatches.last {
            logCycleProfile(
                "workspace=\(workspaceID) stage=current_target_resolved path=window_id index=\(match.offset) elapsed_ms=\(elapsedMS(since: resolutionStartedAt))"
            )
            return match.offset
        }
        logCycleProfile("workspace=\(workspaceID) stage=current_target_resolved path=none elapsed_ms=\(elapsedMS(since: resolutionStartedAt))")
        return nil
    }

    private func workspaceNavigationTargets(workspaceID: String, forCycling: Bool = false) throws -> [WorkspaceNavigationTarget] {
        let targetsStartedAt = currentDate()
        _ = forCycling
        let windows = try indexedWorkspaceWindows(workspaceID: workspaceID)
        let processes = try store.runningProcesses(workspaceID: workspaceID)
        let agentWindows = try store.agentWindows(workspaceID: workspaceID)
        let agentTerminalIDs = Set(agentWindows.compactMap { terminalTargetID(record: $0) })
        let processesByWindowID: [Int: [RunningProcessRecord]] = {
            var map: [String: [RunningProcessRecord]] = [:]
            for process in processes {
                guard let windowID = process.windowID else { continue }
                map[String(windowID), default: []].append(process)
            }
            return Dictionary(
                uniqueKeysWithValues: map.compactMap { key, value in
                    guard let windowID = Int(key) else { return nil }
                    return (windowID, value.sorted { $0.templateName.localizedStandardCompare($1.templateName) == .orderedAscending })
                })
        }()
        var matchedProcessIDs = Set<String>()

        var targets: [WorkspaceNavigationTarget] = []

        for window in windows where window.role == "browser" {
            let isAgentClaimedWindow = terminalTargetID(window: window).map(agentTerminalIDs.contains) ?? false
            guard !isAgentClaimedWindow else { continue }
            targets.append(.browser(window))
        }

        for window in windows where window.role != "browser" {
            let windowProcesses = (window.role == "terminal" ? processesByWindowID[window.windowID ?? -1] : nil) ?? []
            let isAgentClaimedWindow = terminalTargetID(window: window).map(agentTerminalIDs.contains) ?? false
            let nonAgentWindowProcesses = windowProcesses.filter { process in
                guard let terminalID = terminalTargetID(process: process) else { return true }
                return !agentTerminalIDs.contains(terminalID)
            }
            if window.role == "terminal", !nonAgentWindowProcesses.isEmpty {
                for process in nonAgentWindowProcesses {
                    matchedProcessIDs.insert(process.id)
                    targets.append(.process(process))
                }
                continue
            }
            if isAgentClaimedWindow { continue }
            targets.append(.window(window))
        }

        let orphanedProcesses = processes.filter { process in
            !matchedProcessIDs.contains(process.id) && terminalTargetID(process: process).map { !agentTerminalIDs.contains($0) } != false
        }.sorted { $0.templateName.localizedStandardCompare($1.templateName) == .orderedAscending }
        for process in orphanedProcesses { targets.append(.process(process)) }
        for record in agentWindows.sorted(by: { ($0.label ?? "").localizedStandardCompare($1.label ?? "") == .orderedAscending }) {
            targets.append(.agent(record))
        }

        logCycleProfile(
            "workspace=\(workspaceID) stage=build_targets mode=dedicated count=\(targets.count) windows=\(windows.count) processes=\(processes.count) agents=\(agentWindows.count) elapsed_ms=\(elapsedMS(since: targetsStartedAt))"
        )
        return targets
    }

    private func navigationTargetWindowID(_ target: WorkspaceNavigationTarget) -> Int? {
        switch target {
        case .agent(let record): return try? trackedAgentWindowID(record)
        case .browser(let window), .window(let window): return window.windowID
        case .process(let process): return process.windowID
        }
    }

    private func navigationTargetTerminalID(_ target: WorkspaceNavigationTarget) -> String? {
        switch target {
        case .agent(let record): return terminalTargetID(record: record)
        case .process(let process): return terminalTargetID(process: process)
        case .window(let window): return terminalTargetID(window: window)
        case .browser: return nil
        }
    }

    private func navigationTargetBrowserURL(_ target: WorkspaceNavigationTarget) -> String? {
        switch target {
        case .browser(let window), .window(let window): return window.targetURL
        case .agent, .process: return nil
        }
    }

    private func focusNavigationTarget(_ target: WorkspaceNavigationTarget, workspaceID: String) throws -> Bool {
        switch target {
        case .agent(let record): return try focusAgentWindowRecord(record)
        case .browser(let window), .window(let window): return focusTrackedWindow(window, workspaceID: workspaceID)
        case .process(let process): return try focusWorkspaceProcessRecord(process, workspaceID: workspaceID)
        }
    }

    private func navigationCursor(for target: WorkspaceNavigationTarget) -> WorkspaceNavigationCursor? {
        switch target {
        case .agent(let record):
            if let terminalID = terminalTargetID(record: record), !terminalID.isEmpty { return .terminal(terminalID) }
            if let windowID = record.windowID ?? record.yabaiWindowID { return .window(windowID) }
        case .browser(let window):
            if let browserURL = window.targetURL, !browserURL.isEmpty, let windowID = window.windowID {
                return .browserWindowURL(windowID, browserURL)
            }
            if let browserURL = window.targetURL, !browserURL.isEmpty { return .browserURL(browserURL) }
            if let windowID = window.windowID { return .window(windowID) }
        case .process(let process):
            if let terminalID = terminalTargetID(process: process), !terminalID.isEmpty { return .terminal(terminalID) }
            if let windowID = process.windowID { return .window(windowID) }
        case .window(let window):
            if let terminalID = terminalTargetID(window: window), !terminalID.isEmpty { return .terminal(terminalID) }
            if let windowID = window.windowID { return .window(windowID) }
        }
        return nil
    }

    private func navigationTarget(for window: WindowRecord) -> WorkspaceNavigationTarget {
        window.role == "browser" ? .browser(window) : .window(window)
    }

    private func focusableWorkspaceTargets(workspaceID: String) throws -> [(name: String, target: FocusableWorkspaceTarget)] {
        try validateWorkspaceFocusNames(workspaceID: workspaceID)
        let runtimeTargets = try workspaceNavigationTargets(workspaceID: workspaceID)
        let runtimeProcessNames = Set(try store.runningProcesses(workspaceID: workspaceID).map { normalizedFocusName($0.templateName) })
        let runtimeBrowserURLs = Set(
            runtimeTargets.compactMap { target -> String? in
                guard case .browser(let window) = target else { return nil }
                guard let targetURL = sanitizedFocusName(window.targetURL) else { return nil }
                return normalizedFocusName(targetURL)
            })
        let configuredBrowsers = try resolvedBrowserSessionsForFocusNames(workspaceID: workspaceID)
        let configuredProcesses = try store.workspaceProcesses(workspaceID: workspaceID)

        var results: [(name: String, target: FocusableWorkspaceTarget)] = []
        var seen = Set<String>()

        func append(_ name: String?, target: FocusableWorkspaceTarget) {
            guard let name = sanitizedFocusName(name) else { return }
            let normalized = normalizedFocusName(name)
            guard !seen.contains(normalized) else { return }
            seen.insert(normalized)
            results.append((name, target))
        }

        for target in runtimeTargets { append(try focusName(for: target, workspaceID: workspaceID), target: focusableTarget(from: target)) }

        for session in configuredBrowsers where !runtimeBrowserURLs.contains(normalizedFocusName(session.targetURL)) {
            append(session.name, target: .browserSession(targetURL: session.targetURL))
        }

        for process in configuredProcesses {
            let processName = sanitizedFocusName(process.name ?? process.command)
            guard let processName else { continue }
            guard !runtimeProcessNames.contains(normalizedFocusName(processName)) else { continue }
            append(processName, target: .configuredProcess(name: processName))
        }

        return results
    }

    private func focusableTarget(from target: WorkspaceNavigationTarget) -> FocusableWorkspaceTarget {
        switch target {
        case .agent(let record): return .agent(record)
        case .browser(let window): return .window(window)
        case .process(let process): return .process(process)
        case .window(let window): return .window(window)
        }
    }

    private func focusName(for target: WorkspaceNavigationTarget, workspaceID: String) throws -> String? {
        switch target {
        case .agent(let record): return sanitizedFocusName(record.label)
        case .browser(let window): return sanitizedFocusName(window.name)
        case .process(let process): return sanitizedFocusName(process.templateName)
        case .window(let window): return sanitizedFocusName(window.name)
        }
    }

    private func rememberNavigationTarget(_ target: WorkspaceNavigationTarget, workspaceID: String) {
        setWindowNavigationCursor(navigationCursor(for: target), workspaceID: workspaceID)
    }

    private func sanitizedFocusName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func generatedAdHocTerminalWindowName(workspaceID: String) throws -> String {
        let usedNames = Set(try workspaceFocusableWindowNames(workspaceID: workspaceID).map(normalizedFocusName))
        var suffix = 1
        while usedNames.contains(normalizedFocusName("shell-\(suffix)")) { suffix += 1 }
        return "shell-\(suffix)"
    }

    private func uniqueAgentFocusLabel(
        workspaceID: String, preferredLabel: String?, excludingAgentWindowID: String? = nil, claimedLauncherName: String? = nil
    ) throws -> String? {
        guard let baseLabel = sanitizedFocusName(preferredLabel) else { return nil }
        // Configured coding-agent slots reserve their exact names even before a live agent
        // reports in. Ad-hoc agents that choose the same label get suffixed so the Run tab
        // and `mx workspace focus --name ...` keep a stable one-name-to-one-row mapping.
        let usedNames = Set(
            try focusableWorkspaceTargets(workspaceID: workspaceID).filter { entry in
                guard case .agent(let record) = entry.target, let excludingAgentWindowID else { return true }
                return record.id != excludingAgentWindowID
            }.map(\.name).map(normalizedFocusName))
        let existingAgentNames = try store.agentWindows(workspaceID: workspaceID).filter { $0.id != excludingAgentWindowID }.compactMap(\.label)
            .compactMap(sanitizedFocusName).map(normalizedFocusName)
        let reservedLauncherNames = Set(
            try store.workspaceAgentLaunchers(workspaceID: workspaceID).map { try requiredConfiguredFocusName($0.name, kind: "Coding agent") }.filter
            { launcherName in
                guard let claimedLauncherName else { return true }
                return normalizedFocusName(launcherName) != normalizedFocusName(claimedLauncherName)
            }.map(normalizedFocusName))
        var blockedNames = usedNames
        blockedNames.formUnion(existingAgentNames)
        blockedNames.formUnion(reservedLauncherNames)
        if !blockedNames.contains(normalizedFocusName(baseLabel)) { return baseLabel }
        var suffix = 2
        while blockedNames.contains(normalizedFocusName("\(baseLabel)-\(suffix)")) { suffix += 1 }
        return "\(baseLabel)-\(suffix)"
    }

    private func normalizedFocusName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func browserFocusName(workspaceID: String, targetURL: String?) throws -> String? {
        guard let targetURL = sanitizedFocusName(targetURL) else { return nil }
        let sessions = try resolvedBrowserSessionsForFocusNames(workspaceID: workspaceID)
        if let match = sessions.filter({ targetURL.hasPrefix($0.targetURL) }).max(by: { $0.targetURL.count < $1.targetURL.count }) {
            return match.name
        }
        return targetURL
    }

    private func resolvedBrowserSessionsForFocusNames(workspaceID: String, browserSessions: [BrowserSession]? = nil) throws -> [(
        name: String, targetURL: String
    )] {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let sessions = try browserSessions ?? store.workspaceBrowserSessions(workspaceID: workspace.id)
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        return try resolveBrowserSessions(sessions, env: env).compactMap { resolved in
            guard let targetURL = sanitizedFocusName(resolved.prefix) else { return nil }
            let name = try requiredConfiguredFocusName(resolved.session.name, kind: "Browser session")
            return (name, targetURL)
        }
    }

    private func requiredConfiguredFocusName(_ name: String?, kind: String) throws -> String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let sanitized = sanitizedFocusName(trimmedName), !sanitized.isEmpty else {
            throw MuxyError.invalidArgument(message: "\(kind) name is required.")
        }
        return sanitized
    }

    private func validateUniqueConfiguredFocusNames(processes: [ProcessTemplate], browserSessions: [BrowserSession], agentLaunchers: [AgentLauncher])
        throws
    {
        let processEntries = try processes.map { process in (name: try requiredConfiguredFocusName(process.name, kind: "Process"), kind: "process") }
        let browserEntries = try browserSessions.map { session in
            (name: try requiredConfiguredFocusName(session.name, kind: "Browser session"), kind: "browser session")
        }
        let launcherEntries = try agentLaunchers.map { launcher in
            (name: try requiredConfiguredFocusName(launcher.name, kind: "Coding agent"), kind: "coding agent")
        }
        let entries = processEntries + browserEntries + launcherEntries
        try validateUniqueFocusNameEntries(entries)
    }

    private func validateWorkspaceFocusNames(
        workspaceID: String, processes: [ProcessTemplate]? = nil, browserSessions: [BrowserSession]? = nil, agentLaunchers: [AgentLauncher]? = nil,
        agentWindows: [AgentWindowRecord]? = nil
    ) throws {
        let workspaceProcesses = try processes ?? store.workspaceProcesses(workspaceID: workspaceID)
        let workspaceBrowserSessions = try browserSessions ?? store.workspaceBrowserSessions(workspaceID: workspaceID)
        let workspaceAgentLaunchers = try agentLaunchers ?? store.workspaceAgentLaunchers(workspaceID: workspaceID)
        let workspaceAgentWindows = try agentWindows ?? store.agentWindows(workspaceID: workspaceID)
        let configuredAgentNames = Set(
            try workspaceAgentLaunchers.map { try requiredConfiguredFocusName($0.name, kind: "Coding agent") }.map(normalizedFocusName))
        let processEntries = try workspaceProcesses.map { process in
            (name: try requiredConfiguredFocusName(process.name, kind: "Process"), kind: "process")
        }
        let entries =
            processEntries
            + (try resolvedBrowserSessionsForFocusNames(workspaceID: workspaceID, browserSessions: workspaceBrowserSessions).map {
                ($0.name, "browser session")
            })
            + (try workspaceAgentLaunchers.map { launcher in
                (name: try requiredConfiguredFocusName(launcher.name, kind: "Coding agent"), kind: "coding agent")
            })
            + workspaceAgentWindows.compactMap { record -> (name: String, kind: String)? in
                guard let name = sanitizedFocusName(record.label) else { return nil }
                guard !configuredAgentNames.contains(normalizedFocusName(name)) else { return nil }
                return (name, "terminal")
            }
        try validateUniqueFocusNameEntries(entries)
    }

    private func validateUniqueFocusNameEntries(_ entries: [(name: String, kind: String)]) throws {
        var countsByName: [String: Int] = [:]
        var originalNameByNormalized: [String: String] = [:]
        for entry in entries {
            let normalized = normalizedFocusName(entry.name)
            countsByName[normalized, default: 0] += 1
            originalNameByNormalized[normalized] = originalNameByNormalized[normalized] ?? entry.name
        }
        let duplicates = countsByName.compactMap { normalized, count -> String? in
            guard count > 1 else { return nil }
            return originalNameByNormalized[normalized]
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !duplicates.isEmpty else { return }
        throw MuxyError.invalidArgument(
            message: "Names must be unique across browser sessions, processes, and coding agents. Duplicates: \(duplicates.joined(separator: ", "))")
    }

    private func missingFocusNameMessage(name: String, availableNames: [String]) -> String {
        guard !availableNames.isEmpty else { return "Window '\(name)' was not found. No focusable window names are available for this workspace." }
        return "Window '\(name)' was not found. Available names: \(availableNames.joined(separator: ", "))"
    }

    private func navigationTargetIndex(cursor: WorkspaceNavigationCursor, targets: [WorkspaceNavigationTarget]) -> Int? {
        targets.enumerated().first(where: { navigationCursor(for: $0.element) == cursor })?.offset
    }

    private func rememberFocusedNavigationTarget(workspaceID: String) throws {
        let targets = try workspaceNavigationTargets(workspaceID: workspaceID)
        guard !targets.isEmpty else {
            setWindowNavigationCursor(nil, workspaceID: workspaceID)
            return
        }
        let cursor = try currentFocusedNavigationTargetIndex(targets: targets, workspaceID: workspaceID).flatMap {
            navigationCursor(for: targets[$0])
        }
        setWindowNavigationCursor(cursor, workspaceID: workspaceID)
    }

    private func windowNavigationCursor(workspaceID: String) -> WorkspaceNavigationCursor? {
        windowNavigationLock.lock()
        defer { windowNavigationLock.unlock() }
        return windowNavigationCursorByWorkspace[workspaceID]
    }

    private func setWindowNavigationCursor(_ cursor: WorkspaceNavigationCursor?, workspaceID: String) {
        windowNavigationLock.lock()
        if let cursor {
            windowNavigationCursorByWorkspace[workspaceID] = cursor
        } else {
            windowNavigationCursorByWorkspace.removeValue(forKey: workspaceID)
        }
        windowNavigationLock.unlock()
    }

    private func focusTrackedWindow(_ window: WindowRecord, workspaceID: String) -> Bool {
        let focusStartedAt = currentDate()
        let focused: Bool
        if window.role == "browser", let windowID = window.windowID {
            let focusedWindow = (try? yabai.focusWindow(id: windowID)) ?? false
            if focusedWindow, chrome.isAvailable() { _ = try? chrome.focusFirstTabOfFrontWindow() }
            focused = focusedWindow
        } else {
            let trackingIdentity = resolvedFocusIdentity(for: window, workspaceID: workspaceID)
            let adapterFocused = focusManagedTerminal(
                terminalApp: window.app, trackingIdentity: trackingIdentity, windowID: window.windowID, tabIndex: window.itermTabIndex)
            focused = adapterFocused == true ? true : ((window.windowID.flatMap { try? yabai.focusWindow(id: $0) }) ?? false)
        }
        guard let id = window.windowID else { return focused }
        if !focused, window.role == "browser", let targetURL = window.targetURL {
            try? markBrowserWindowMissing(workspaceID: workspaceID, targetURL: targetURL, windowID: id)
        }
        if focused, window.role == "terminal" { pulseTerminalWindowIfNeeded(windowID: id) }
        logBrowserFocus(
            "workspace=\(workspaceID) path=yabai window=\(id) success=\(focused ? "1" : "0") elapsed_ms=\(elapsedMS(since: focusStartedAt))")
        return focused
    }

    private func focusTrackedWindowOrRecoverBrowserWindow(_ window: WindowRecord, workspaceID: String) throws -> Bool {
        let focused = focusTrackedWindow(window, workspaceID: workspaceID)
        guard !focused, window.role == "browser", let targetURL = window.targetURL else { return focused }
        try recoverMissingBrowserSession(workspaceID: workspaceID, targetURL: targetURL)
        return true
    }

    private func closeTrackedItermTerminalContainer(_ process: RunningProcessRecord) throws -> Bool {
        guard isManagedTerminalApp(process.terminalApp) else { return false }
        guard let windowID = process.windowID else { return false }
        return (try? yabai.closeWindow(id: windowID)) != nil
    }

    private func closeTrackedItermTerminalWindow(_ trackedWindow: WindowRecord) throws -> Bool {
        guard let windowID = trackedWindow.windowID else { return false }
        return (try? yabai.closeWindow(id: windowID)) != nil
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
        guard let existing = windows.first(where: { $0.role == "terminal" && isManagedTerminalApp($0.app) && $0.windowID == windowID }) else {
            return
        }
        let updated = WindowRecord(
            id: existing.id, workspaceID: existing.workspaceID, app: existing.app, name: existing.name, detail: existing.detail,
            targetURL: existing.targetURL, windowID: existing.windowID, terminalTrackingID: sessionID, terminalNativeID: existing.terminalNativeID,
            itermTabIndex: tabIndex, tmuxWindowID: existing.tmuxWindowID, role: existing.role, orderIndex: existing.orderIndex,
            lastSeenAt: nowISO8601())
        try store.upsert(window: updated)
    }

    private func tmuxSessionName(workspaceID: String) -> String { "muxy-\(workspaceID)" }

    private func terminalTargetID(process: RunningProcessRecord) -> String? { process.terminalTrackingKey }

    private func terminalTargetID(record: AgentWindowRecord) -> String? { record.terminalTrackingKey }

    private func terminalTargetID(window: WindowRecord) -> String? { window.terminalTrackingKey }

    private func configuredTerminalHost() throws -> TerminalHost { try store.appConfig().terminalHost }

    private func terminalHost(for appName: String?) -> TerminalHost? {
        guard let appName else { return nil }
        return TerminalHost.allCases.first(where: { $0.appName == appName })
    }

    private func agentProvider(for terminalHost: TerminalHost) -> AgentProvider {
        switch terminalHost {
        case .iterm2: return .iterm2
        case .ghostty: return .ghostty
        }
    }

    private func terminalAppName(for terminalHost: TerminalHost) -> String { terminalHost.appName }

    private func isManagedTerminalApp(_ appName: String?) -> Bool { terminalHost(for: appName) != nil }

    private func terminalAdapter(for terminalHost: TerminalHost) -> (any TerminalAdapter)? { terminalAdaptersByHost[terminalHost] }

    private func storedTerminalHookSessionID(terminalHost: TerminalHost, handle: ManagedTerminalHandle) -> String? {
        switch terminalHost {
        case .ghostty: return handle.hookSessionID ?? handle.trackingIdentity?.sessionID
        case .iterm2: return handle.trackingIdentity?.sessionID
        }
    }

    private func storedTerminalNativeID(terminalHost: TerminalHost, handle: ManagedTerminalHandle) -> String? {
        guard terminalHost == .ghostty else { return nil }
        return handle.trackingIdentity?.sessionID
    }

    private func resolvedFocusIdentity(for window: WindowRecord, workspaceID: String) -> TerminalTrackingIdentity? {
        if let terminalHost = terminalHost(for: window.app), terminalHost == .ghostty, let focusIdentity = window.terminalFocusIdentity {
            return focusIdentity
        }
        if let sessionID = window.terminalTrackingID, !sessionID.isEmpty { return .session(sessionID) }
        guard window.role == "terminal" else { return nil }
        if let windowID = window.windowID {
            if let processIdentity = try? store.runningProcesses(workspaceID: workspaceID).first(where: {
                $0.windowID == windowID && $0.terminalApp == window.app && $0.terminalFocusIdentity != nil
            })?.terminalFocusIdentity {
                return processIdentity
            }
            if let agentIdentity = try? store.agentWindows(workspaceID: workspaceID).first(where: {
                TerminalHost(rawValue: $0.provider.rawValue)?.appName == window.app && (($0.yabaiWindowID ?? $0.windowID) == windowID)
                    && $0.terminalFocusIdentity != nil
            })?.terminalFocusIdentity {
                return agentIdentity
            }
            return .window(windowID)
        }
        if let tmuxWindowID = window.tmuxWindowID, !tmuxWindowID.isEmpty { return .tmux(tmuxWindowID) }
        return nil
    }

    private func focusManagedTerminal(terminalApp: String?, trackingIdentity: TerminalTrackingIdentity?, windowID: Int?, tabIndex: Int?) -> Bool? {
        guard let terminalHost = terminalHost(for: terminalApp), let terminalAdapter = terminalAdapter(for: terminalHost) else { return nil }
        let hasPreciseTarget = trackingIdentity != nil || tabIndex != nil
        guard hasPreciseTarget else { return nil }
        let target = TerminalFocusTarget(trackingIdentity: trackingIdentity, windowID: windowID, tabIndex: tabIndex)
        return try? terminalAdapter.focusTrackedTerminal(target)
    }

    private func pulseTerminalWindowIfNeeded(windowID: Int) {
        guard (try? windowFocusPulseEnabled()) ?? SettingsKey.defaultWindowFocusPulseEnabled else { return }
        let color = (try? windowFocusPulseColor()) ?? defaultWindowFocusPulseColor()
        terminalFocusPulseController.pulse(windowID: windowID, color: color, yabai: yabai)
    }

    private func terminalAdapterAvailable(_ terminalHost: TerminalHost) -> Bool { terminalAdapter(for: terminalHost)?.isAvailable() == true }

    private func missingTerminalDependencyMessage(for terminalHost: TerminalHost, operation: String) -> String {
        "\(terminalHost.displayName) is required to \(operation)."
    }

    private func openManagedTerminalWindow(
        terminalHost: TerminalHost, command: String, cwd: String, environment: [String: String] = [:], background: Bool = false
    ) throws -> ManagedTerminalHandle {
        guard let terminalAdapter = terminalAdapter(for: terminalHost) else {
            throw MuxyError.invalidArgument(message: "Unsupported terminal host: \(terminalHost.rawValue)")
        }
        let result = try terminalAdapter.openWindowAndRun(command: command, cwd: cwd, environment: environment, background: background)
        return ManagedTerminalHandle(
            fallbackWindowID: result.fallbackWindowID, trackingIdentity: result.trackingIdentity, hookSessionID: result.hookSessionID)
    }

    private func workspaceTerminalWindowID(workspaceID: String) throws -> Int? {
        let liveWindowIDs = Set(try yabai.listWindows().filter { isManagedTerminalApp($0.app) }.map(\.id))
        let windowIDs = try store.windows(workspaceID: workspaceID).filter { $0.role == "terminal" && isManagedTerminalApp($0.app) }.compactMap(
            \.windowID)
        let processWindowIDs = try store.runningProcesses(workspaceID: workspaceID).compactMap(\.windowID)
        let agentWindowIDs = try store.agentWindows(workspaceID: workspaceID).compactMap { $0.windowID ?? $0.yabaiWindowID }
        let candidateWindowIDs = windowIDs + processWindowIDs + agentWindowIDs
        return candidateWindowIDs.first(where: { liveWindowIDs.contains($0) })
    }

    private func workspaceTerminalSessionID(workspaceID: String) throws -> String? {
        if let sessionID = try store.windows(workspaceID: workspaceID).first(where: {
            $0.role == "terminal" && isManagedTerminalApp($0.app) && ($0.terminalTrackingID?.isEmpty == false)
        })?.terminalTrackingID {
            return sessionID
        }
        if let sessionID = try store.runningProcesses(workspaceID: workspaceID).first(where: { $0.terminalTrackingID?.isEmpty == false })?
            .terminalTrackingID
        {
            return sessionID
        }
        return try store.agentWindows(workspaceID: workspaceID).first(where: { $0.terminalTrackingID?.isEmpty == false })?.terminalTrackingID
    }

    private func waitForTmuxSession(named sessionName: String, timeout: TimeInterval = 5.0) -> Bool {
        let deadline = currentDate().addingTimeInterval(timeout)
        while currentDate() < deadline {
            if tmux.hasSession(named: sessionName) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return tmux.hasSession(named: sessionName)
    }

    private func workspaceAttachCommand(workspace: WorkspaceRecord) -> String {
        "cd \(shellSingleQuoted(workspace.dir)) && exec tmux new-session -A -s \(shellSingleQuoted(tmuxSessionName(workspaceID: workspace.id))) -c \(shellSingleQuoted(workspace.dir))"
    }

    private func processTmuxSessionName(workspaceID: String, processName: String) -> String {
        "muxy-\(workspaceID)-\(safeFilename(processName).lowercased())"
    }

    private func shellSingleQuoted(_ raw: String) -> String { "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'" }

    private func tmuxAttachCommand(sessionName: String, cwd: String) -> String {
        "cd \(shellSingleQuoted(cwd)) && exec tmux attach-session -t \(shellSingleQuoted(sessionName))"
    }

    @discardableResult private func attachProcessTmuxSession(
        workspace: WorkspaceRecord, processName: String, commandDescription: String? = nil, terminalHost: TerminalHost, background: Bool = false
    ) throws -> ManagedTerminalHandle {
        let sessionName = processTmuxSessionName(workspaceID: workspace.id, processName: processName)
        let windowInfo = try openManagedTerminalWindow(
            terminalHost: terminalHost, command: tmuxAttachCommand(sessionName: sessionName, cwd: workspace.dir), cwd: workspace.dir,
            background: background)
        guard waitForTmuxSession(named: sessionName) else {
            throw MuxyError.invalidArgument(message: tmuxSessionTimeoutMessage(processName: processName, commandDescription: commandDescription))
        }
        return windowInfo
    }

    private func launchProcessInTmux(
        workspace: WorkspaceRecord, processName: String, rawCommand: String, command: DirectProcessCommand, env: [String: String],
        terminalHost: TerminalHost, background: Bool = false, replaceExistingSession: Bool
    ) throws -> ManagedTerminalHandle {
        let sessionName = processTmuxSessionName(workspaceID: workspace.id, processName: processName)
        if replaceExistingSession, tmux.hasSession(named: sessionName) { try? tmux.killSession(named: sessionName) }
        _ = try tmux.startSession(
            named: sessionName, windowName: processName, cwd: workspace.dir, env: env.merging(command.environment) { _, new in new },
            command: [command.executable] + command.arguments)
        let windowInfo = try attachProcessTmuxSession(
            workspace: workspace, processName: processName, commandDescription: rawCommand, terminalHost: terminalHost, background: background)
        guard waitForTmuxSession(named: sessionName) else {
            throw MuxyError.invalidArgument(message: tmuxSessionTimeoutMessage(processName: processName, commandDescription: rawCommand))
        }
        return windowInfo
    }

    private func currentTmuxWindowInfo(workspaceID: String, processName: String) throws -> TmuxWindowInfo? {
        try tmux.currentWindow(sessionName: processTmuxSessionName(workspaceID: workspaceID, processName: processName))
    }

    private func interactiveShellCommand(cwd: String) -> String {
        let escapedDir = cwd.replacingOccurrences(of: "\"", with: "\\\"")
        return #"bash -lc 'cd "\#(escapedDir)" && exec "${SHELL:-/bin/zsh}" -l'"#
    }

    private func terminalLaunchEnvironment(base: [String: String], terminalHost: TerminalHost) -> [String: String] {
        var env = base
        for key in [DatabaseLocator.databasePathEnvironmentVariable, "MUXY_RUNTIME_DIR", "MUXY_E2E_EVENTS_LOG", "DEBUG"] {
            if let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                env[key] = value
            }
        }
        guard terminalHost == .ghostty else { return env }
        env[Self.terminalTrackingIDEnvVar] = UUID().uuidString
        return env
    }

    private struct DirectTerminalCommand {
        let executable: String
        let arguments: [String]
    }

    private struct DirectProcessCommand {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    private func shellQuoted(_ token: String) -> String {
        guard !token.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/:")
        if token.unicodeScalars.allSatisfy({ safe.contains($0) }) { return token }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func parseDirectTerminalCommand(_ raw: String) -> DirectTerminalCommand? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var iterator = trimmed.makeIterator()

        while let char = iterator.next() {
            if let currentQuote = quote {
                if char == currentQuote {
                    quote = nil
                    continue
                }
                if char == "\\" && currentQuote == "\"" {
                    if let escaped = iterator.next() { current.append(escaped) } else { current.append(char) }
                    continue
                }
                current.append(char)
                continue
            }

            switch char {
            case "'", "\"": quote = char
            case " ", "\t", "\n":
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            case "\\": if let escaped = iterator.next() { current.append(escaped) } else { current.append(char) }
            case "|", "&", ";", "<", ">", "(", ")", "$", "`": return nil
            default: current.append(char)
            }
        }

        guard quote == nil else { return nil }
        if !current.isEmpty { tokens.append(current) }
        guard let executable = tokens.first else { return nil }
        return DirectTerminalCommand(executable: executable, arguments: Array(tokens.dropFirst()))
    }

    private func parseDirectProcessCommand(_ raw: String, env: [String: String]) -> DirectProcessCommand? {
        guard let parsed = parseDirectTerminalCommand(applyEnvVars(raw, env: env)) else { return nil }
        let tokens = [parsed.executable] + parsed.arguments
        var commandEnvironment: [String: String] = [:]
        var executableIndex: Int?

        for (index, token) in tokens.enumerated() {
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts.first.map(String.init) ?? ""
            let isAssignment =
                parts.count == 2 && !key.isEmpty && (key.first?.isLetter == true || key.first == "_")
                && key.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            if executableIndex == nil, isAssignment {
                commandEnvironment[key] = String(parts[1])
                continue
            }
            executableIndex = index
            break
        }

        guard let executableIndex else { return nil }
        return DirectProcessCommand(
            executable: tokens[executableIndex], arguments: Array(tokens.dropFirst(executableIndex + 1)), environment: commandEnvironment)
    }

    private func invalidDirectProcessCommandMessage(_ raw: String, env: [String: String]) -> String {
        let resolved = applyEnvVars(raw, env: env)
        return
            "Process commands must be direct executable invocations without shell syntax: \(resolved). For composite commands, wrap them explicitly, for example: bash -lc \"\(resolved)\""
    }

    private func tmuxSessionTimeoutMessage(processName: String, commandDescription: String?) -> String {
        let trimmedProcessName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = commandDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCommand, !trimmedCommand.isEmpty, !trimmedProcessName.isEmpty {
            return "Timed out waiting for tmux session to become available for process '\(trimmedProcessName)' (\(trimmedCommand))."
        }
        if let trimmedCommand, !trimmedCommand.isEmpty {
            return "Timed out waiting for tmux session to become available for command '\(trimmedCommand)'."
        }
        if !trimmedProcessName.isEmpty { return "Timed out waiting for tmux session to become available for process '\(trimmedProcessName)'." }
        return "Timed out waiting for tmux session to become available."
    }

    @discardableResult private func ensureWorkspaceTerminalAttached(workspace: WorkspaceRecord, background: Bool = false) throws -> ItermWindowInfo {
        if let windowID = try workspaceTerminalWindowID(workspaceID: workspace.id) {
            return ItermWindowInfo(id: windowID, sessionID: try workspaceTerminalSessionID(workspaceID: workspace.id), tabIndex: nil)
        }

        let windowInfo = try iterm.openWindowAndRun(command: workspaceAttachCommand(workspace: workspace), background: background)
        guard waitForTmuxSession(named: tmuxSessionName(workspaceID: workspace.id)) else {
            throw MuxyError.invalidArgument(message: "Timed out waiting for tmux session to become available.")
        }
        try rebindWorkspaceTerminalWindow(workspaceID: workspace.id, windowID: windowInfo.id, sessionID: windowInfo.sessionID)
        return windowInfo
    }

    private func tmuxWindows(workspaceID: String) throws -> [TmuxWindowInfo] {
        let configuredProcessNames = try store.workspaceProcesses(workspaceID: workspaceID).map { $0.name ?? $0.command }
        let runningProcessNames = try store.runningProcesses(workspaceID: workspaceID).map(\.templateName)
        var sessionNames: [String] = [tmuxSessionName(workspaceID: workspaceID)]
        for processName in configuredProcessNames + runningProcessNames {
            let sessionName = processTmuxSessionName(workspaceID: workspaceID, processName: processName)
            if !sessionNames.contains(sessionName) { sessionNames.append(sessionName) }
        }

        var windows: [TmuxWindowInfo] = []
        var seenWindowIDs = Set<String>()
        for sessionName in sessionNames {
            for window in try tmux.listWindows(sessionName: sessionName) where !seenWindowIDs.contains(window.id) {
                seenWindowIDs.insert(window.id)
                windows.append(window)
            }
        }
        return windows
    }

    private func liveTmuxWindow(workspaceID: String, windowID: String) throws -> TmuxWindowInfo? {
        try tmuxWindows(workspaceID: workspaceID).first(where: { $0.id == windowID })
    }

    private func rebindWorkspaceTerminalWindow(workspaceID: String, windowID: Int, sessionID: String?) throws {
        let now = nowISO8601()
        for window in try store.windows(workspaceID: workspaceID) where window.role == "terminal" && isManagedTerminalApp(window.app) {
            try store.upsert(
                window: WindowRecord(
                    id: window.id, workspaceID: window.workspaceID, app: window.app, name: window.name, detail: window.detail,
                    targetURL: window.targetURL, windowID: windowID, terminalTrackingID: sessionID ?? window.terminalTrackingID,
                    terminalNativeID: window.terminalNativeID, itermTabIndex: nil, tmuxWindowID: window.tmuxWindowID, role: window.role,
                    orderIndex: window.orderIndex, lastSeenAt: now))
        }
        for process in try store.runningProcesses(workspaceID: workspaceID) where isManagedTerminalApp(process.terminalApp) {
            try store.upsert(
                runningProcess: RunningProcessRecord(
                    id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                    terminalApp: process.terminalApp, windowID: windowID, terminalTrackingID: sessionID ?? process.terminalTrackingID,
                    terminalNativeID: process.terminalNativeID, itermTabIndex: nil, tmuxWindowID: process.tmuxWindowID, pid: process.pid,
                    status: process.status, logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt,
                    exitedAt: process.exitedAt))
        }
        for agent in try store.agentWindows(workspaceID: workspaceID) where TerminalHost(rawValue: agent.provider.rawValue) != nil {
            try store.upsertAgentWindow(
                AgentWindowRecord(
                    id: agent.id, workspaceID: agent.workspaceID, provider: agent.provider, label: agent.label,
                    terminalTrackingID: sessionID ?? agent.terminalTrackingID, terminalNativeID: agent.terminalNativeID,
                    tmuxWindowID: agent.tmuxWindowID, codexThreadID: agent.codexThreadID, windowID: windowID, yabaiWindowID: windowID,
                    status: agent.status, createdAt: agent.createdAt, updatedAt: now))
        }
        setItermTerminalSessionMetadata(workspaceID: workspaceID, windowID: windowID, sessionID: sessionID, tabIndex: nil)
    }

    private func createOrRespawnTmuxWindow(
        workspace: WorkspaceRecord, name: String, command: String, existingWindowID: String? = nil, remainOnExit: Bool = true
    ) throws -> TmuxWindowInfo {
        let sessionName = tmuxSessionName(workspaceID: workspace.id)
        if let existingWindowID {
            try tmux.renameWindow(windowID: existingWindowID, name: name)
            try tmux.respawnWindow(windowID: existingWindowID, command: command)
            try tmux.setRemainOnExit(windowID: existingWindowID, enabled: remainOnExit)
            if let window = try liveTmuxWindow(workspaceID: workspace.id, windowID: existingWindowID) { return window }
        }
        let window = try tmux.createWindow(sessionName: sessionName, name: name, command: command, detached: true)
        try tmux.setRemainOnExit(windowID: window.id, enabled: remainOnExit)
        return window
    }

    private func matchingProcessCommand(workspaceID: String, tmuxWindowID: String) -> String? {
        try? store.runningProcesses(workspaceID: workspaceID).first(where: { $0.tmuxWindowID == tmuxWindowID })?.command
    }

    private func upsertTmuxTerminalWindow(
        workspaceID: String, windowID: Int?, terminalTrackingID: String?, tmuxWindow: TmuxWindowInfo, lastSeenAt: String = ""
    ) throws -> WindowRecord {
        let existingID = try store.windows(workspaceID: workspaceID).first(where: { $0.tmuxWindowID == tmuxWindow.id })?.id ?? UUID().uuidString
        let terminalApp =
            try store.runningProcesses(workspaceID: workspaceID).first(where: {
                $0.tmuxWindowID == tmuxWindow.id && isManagedTerminalApp($0.terminalApp)
            })?.terminalApp ?? TerminalHost.iterm2.appName
        let record = WindowRecord(
            id: existingID, workspaceID: workspaceID, app: terminalApp, name: tmuxWindow.name,
            detail: matchingProcessCommand(workspaceID: workspaceID, tmuxWindowID: tmuxWindow.id), targetURL: nil, windowID: windowID,
            terminalTrackingID: terminalTrackingID, itermTabIndex: nil, tmuxWindowID: tmuxWindow.id, role: "terminal",
            orderIndex: 200 + tmuxWindow.index, lastSeenAt: lastSeenAt.isEmpty ? nowISO8601() : lastSeenAt)
        try store.upsert(window: record)
        return record
    }

    private func tmuxTerminalWindowRecord(
        workspaceID: String, windowID: Int?, terminalTrackingID: String?, tmuxWindow: TmuxWindowInfo, lastSeenAt: String = ""
    ) -> WindowRecord {
        let now = lastSeenAt.isEmpty ? nowISO8601() : lastSeenAt
        let terminalApp =
            (try? store.runningProcesses(workspaceID: workspaceID).first(where: {
                $0.tmuxWindowID == tmuxWindow.id && isManagedTerminalApp($0.terminalApp)
            })?.terminalApp) ?? TerminalHost.iterm2.appName
        return WindowRecord(
            id: UUID().uuidString, workspaceID: workspaceID, app: terminalApp, name: tmuxWindow.name,
            detail: matchingProcessCommand(workspaceID: workspaceID, tmuxWindowID: tmuxWindow.id), targetURL: nil, windowID: windowID,
            terminalTrackingID: terminalTrackingID, itermTabIndex: nil, tmuxWindowID: tmuxWindow.id, role: "terminal",
            orderIndex: 200 + tmuxWindow.index, lastSeenAt: now)
    }

    @discardableResult private func syncTrackedTmuxRuntime(workspaceID: String) throws -> Bool {
        guard tmux.isAvailable() else { return false }
        let liveTmuxWindows = try tmuxWindows(workspaceID: workspaceID)
        let liveWindowsByID = Dictionary(uniqueKeysWithValues: liveTmuxWindows.map { ($0.id, $0) })
        let liveTmuxWindowIDs = Set(liveWindowsByID.keys)
        let now = nowISO8601()
        var didMutate = false

        for window in try store.windows(workspaceID: workspaceID) where window.role == "terminal" && isManagedTerminalApp(window.app) {
            guard let tmuxWindowID = window.tmuxWindowID else { continue }
            guard let liveTmuxWindow = liveWindowsByID[tmuxWindowID] else {
                try store.deleteWindow(id: window.id)
                didMutate = true
                continue
            }
            let refreshedDetail = matchingProcessCommand(workspaceID: workspaceID, tmuxWindowID: tmuxWindowID)
            if window.name != liveTmuxWindow.name || window.detail != refreshedDetail || window.orderIndex != 200 + liveTmuxWindow.index {
                try store.upsert(
                    window: WindowRecord(
                        id: window.id, workspaceID: window.workspaceID, app: window.app, name: liveTmuxWindow.name, detail: refreshedDetail,
                        targetURL: window.targetURL, windowID: window.windowID, terminalTrackingID: window.terminalTrackingID,
                        terminalNativeID: window.terminalNativeID, itermTabIndex: nil, tmuxWindowID: tmuxWindowID, role: window.role,
                        orderIndex: 200 + liveTmuxWindow.index, lastSeenAt: now))
                didMutate = true
            }
        }

        for process in try store.runningProcesses(workspaceID: workspaceID) where isManagedTerminalApp(process.terminalApp) {
            guard let tmuxWindowID = process.tmuxWindowID else { continue }
            guard liveTmuxWindowIDs.contains(tmuxWindowID) else {
                guard process.status != .exited else { continue }
                // Preserve configured process rows when their tmux window vanishes so an
                // explicit `mx workspace up` can still restart just the dead process.
                try store.upsert(
                    runningProcess: RunningProcessRecord(
                        id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                        terminalApp: process.terminalApp, windowID: process.windowID, terminalTrackingID: process.terminalTrackingID,
                        terminalNativeID: process.terminalNativeID, itermTabIndex: process.itermTabIndex, tmuxWindowID: process.tmuxWindowID,
                        pid: process.pid, status: .exited, logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt,
                        exitedAt: process.exitedAt ?? now))
                didMutate = true
                continue
            }
        }

        for agent in try store.agentWindows(workspaceID: workspaceID) where TerminalHost(rawValue: agent.provider.rawValue) != nil {
            guard let tmuxWindowID = agent.tmuxWindowID else { continue }
            guard liveTmuxWindowIDs.contains(tmuxWindowID) else {
                try store.deleteAgentWindow(id: agent.id)
                didMutate = true
                continue
            }
        }

        return didMutate
    }

    @discardableResult private func pruneStaleItermAgentWindows(workspaceID: String) throws -> Int {
        let liveSessionIDs = liveItermSessionIDs()
        var pruned = 0
        for agent in try store.agentWindows(workspaceID: workspaceID) where agent.provider == .iterm2 {
            guard let sessionID = agent.terminalTrackingID, !sessionID.isEmpty else {
                if agent.tmuxWindowID == nil {
                    try store.deleteAgentWindow(id: agent.id)
                    pruned += 1
                }
                continue
            }
            if let liveSessionIDs, !liveSessionIDs.isEmpty, !liveSessionIDs.contains(sessionID) {
                if agent.tmuxWindowID == nil {
                    try store.deleteAgentWindow(id: agent.id)
                    pruned += 1
                }
            }
        }
        return pruned
    }

    private func indexedWorkspaceWindows(workspaceID: String) throws -> [WindowRecord] {
        try store.windows(workspaceID: workspaceID).sorted { $0.orderIndex < $1.orderIndex }
    }

    private func trackedTerminalWindowsForAgents(workspaceID: String, agentWindows: [AgentWindowRecord]) throws -> [WindowRecord] {
        guard !agentWindows.isEmpty else { return [] }
        let trackedAgentTerminalKeys = Set(agentWindows.compactMap(\.terminalTrackingKey))
        let trackedAgentWindowIDs = Set(agentWindows.compactMap { $0.yabaiWindowID ?? $0.windowID })
        guard !trackedAgentTerminalKeys.isEmpty || !trackedAgentWindowIDs.isEmpty else { return [] }
        // Auto-launched coding agents register their own tracked terminal rows before the
        // workspace launch finishes. Preserve those rows when replacing the workspace
        // window snapshot so stop/restart can still close the actual agent terminals.
        return try store.windows(workspaceID: workspaceID).filter { window in
            guard window.role == "terminal" else { return false }
            if let trackingKey = window.terminalTrackingKey, trackedAgentTerminalKeys.contains(trackingKey) { return true }
            if let windowID = window.windowID, trackedAgentWindowIDs.contains(windowID) { return true }
            return false
        }
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
        if let extractedWindow = session.session.extractedWindow, extractedWindow.isValid,
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
        let startedAt = currentDate()
        let resolveWorkspaceStartedAt = currentDate()
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        logBrowserFocus(
            "workspace=\(workspaceID) path=extracted_substep step=resolve_workspace elapsed_ms=\(elapsedMS(since: resolveWorkspaceStartedAt))")

        let loadSessionsStartedAt = currentDate()
        let sessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        logBrowserFocus(
            "workspace=\(workspaceID) path=extracted_substep step=load_sessions elapsed_ms=\(elapsedMS(since: loadSessionsStartedAt)) count=\(sessions.count)"
        )
        guard !sessions.isEmpty else { return .notMapped }

        let namedPortsStartedAt = currentDate()
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        logBrowserFocus(
            "workspace=\(workspaceID) path=extracted_substep step=load_named_ports elapsed_ms=\(elapsedMS(since: namedPortsStartedAt)) count=\(namedPorts.count)"
        )

        let resolveSessionsStartedAt = currentDate()
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        let resolvedSessions = resolveBrowserSessions(sessions, env: env)
        logBrowserFocus(
            "workspace=\(workspaceID) path=extracted_substep step=resolve_sessions elapsed_ms=\(elapsedMS(since: resolveSessionsStartedAt)) count=\(resolvedSessions.count)"
        )
        guard !resolvedSessions.isEmpty else { return .notMapped }

        let matchSessionStartedAt = currentDate()
        guard let matchedSession = resolvedSessions.filter({ targetURL.hasPrefix($0.prefix) }).max(by: { $0.prefix.count < $1.prefix.count }),
            let extractedWindow = sessions[matchedSession.index].extractedWindow, extractedWindow.isValid
        else { return .notMapped }
        logBrowserFocus(
            "workspace=\(workspaceID) path=extracted_substep step=match_session elapsed_ms=\(elapsedMS(since: matchSessionStartedAt)) window_id=\(extractedWindow.windowID)"
        )

        let focusStartedAt = currentDate()
        let focused = try yabai.focusWindow(id: extractedWindow.windowID)
        logBrowserFocus(
            "workspace=\(workspaceID) path=extracted_substep step=yabai_focus elapsed_ms=\(elapsedMS(since: focusStartedAt)) window_id=\(extractedWindow.windowID) success=\(focused ? 1 : 0)"
        )
        guard focused else {
            let markMissingStartedAt = currentDate()
            try markBrowserWindowMissing(workspaceID: workspace.id, targetURL: targetURL, windowID: extractedWindow.windowID)
            logBrowserFocus(
                "workspace=\(workspaceID) path=extracted_substep step=mark_missing elapsed_ms=\(elapsedMS(since: markMissingStartedAt)) window_id=\(extractedWindow.windowID)"
            )
            return .staleMapping
        }
        logBrowserFocus(
            "workspace=\(workspaceID) path=extracted_substep step=total elapsed_ms=\(elapsedMS(since: startedAt)) window_id=\(extractedWindow.windowID)"
        )
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

    private func markBrowserWindowMissing(workspaceID: String, targetURL: String, windowID: Int) throws {
        let sessions = try store.workspaceBrowserSessions(workspaceID: workspaceID)
        if let index = sessions.firstIndex(where: { $0.extractedWindow?.windowID == windowID || $0.url == targetURL }) {
            try markExtractedWindowInvalid(workspaceID: workspaceID, sessions: sessions, index: index)
        }
        for window in try store.windows(workspaceID: workspaceID) where window.role == "browser" && window.windowID == windowID {
            try store.deleteWindow(id: window.id)
        }
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
                let matchesTarget = {
                    guard let activeURL else { return false }
                    return browserURLMatchesTarget(activeURL, targetURL: targetURL)
                }()
                let matchesWorkspace = {
                    guard let activeURL else { return false }
                    return browserURLMatchesWorkspace(activeURL, browserPrefixes: cachedTarget.browserPrefixes)
                }()
                logBrowserFocus(
                    "workspace=\(workspaceID) indexed_verify window=\(windowID) tab_index=\(cachedTarget.tabIndex) attempt=\(attempt) exact_match=\(matchesTarget ? "1" : "0") workspace_match=\(matchesWorkspace ? "1" : "0") verify_ms=\(elapsedMS(since: verifyStartedAt)) url=\(activeURL ?? "")"
                )
                if matchesTarget {
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

    private func browserURLMatchesTarget(_ url: String, targetURL: String) -> Bool {
        if url == targetURL { return true }
        return url.hasPrefix(targetURL)
    }

    private func elapsedMS(since startedAt: Date) -> Int { Int(currentDate().timeIntervalSince(startedAt) * 1000) }

    private func logCycleProfile(_ message: String) {
        guard debugLoggingEnabled() else { return }
        fputs("muxy: cycle \(message)\n", stderr)
    }

    private func logBrowserFocus(_ message: String) {
        guard debugLoggingEnabled() else { return }
        fputs("muxy: browser focus \(message)\n", stderr)
    }

    private func logPerfMetric(_ metric: String, workspaceID: String, target: String, detail: String = "", elapsedMS: Int, success: Bool) {
        guard debugLoggingEnabled() else { return }
        // Manual real-system E2E parses these `muxy: perf metric=...` lines for
        // focus/cycle timing summaries. Treat the prefix and key/value shape as a
        // compatibility surface for the shell harness when changing debug logs.
        let suffix = detail.isEmpty ? "" : " \(detail)"
        fputs(
            "muxy: perf metric=\(metric) workspace=\(workspaceID) target=\(target) success=\(success ? 1 : 0) elapsed_ms=\(elapsedMS)\(suffix)\n",
            stderr)
    }

    private func debugLoggingEnabled() -> Bool { ProcessInfo.processInfo.environment["DEBUG"] == "1" }

    private func navigationTargetDebugName(_ target: WorkspaceNavigationTarget) -> String {
        switch target {
        case .agent(let record): return "agent:\(record.label ?? record.provider.rawValue)"
        case .browser(let window): return "browser:\(window.targetURL ?? window.name ?? "")"
        case .process(let process): return "process:\(process.templateName)"
        case .window(let window): return "\(window.role):\(window.name ?? window.app)"
        }
    }

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
                    id: UUID().uuidString, workspaceID: workspaceID, app: "Google Chrome",
                    name: try browserFocusName(workspaceID: workspaceID, targetURL: match.tab.url) ?? match.tab.url, detail: match.tab.url,
                    targetURL: match.tab.url, windowID: match.tab.windowID, role: "browser", orderIndex: index, lastSeenAt: nowISO8601()))
        }
        if debugLoggingEnabled() {
            let elapsedMS = Int(Date().timeIntervalSince(scanStartedAt) * 1000)
            fputs("muxy: browser scan workspace=\(workspaceID) tabs=\(tabs.count) matches=\(browserWindows.count) elapsed_ms=\(elapsedMS)\n", stderr)
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

    public func guiLeaderHotkey() throws -> String { HotkeySpec.normalizedModifierSet(try guiLeaderModifiers()) }

    public func setGUILeaderHotkey(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiLeaderHotkey, value: raw) }

    public func guiDashboardShortcut() throws -> String {
        try effectiveLeaderBackedShortcut(settingKey: SettingsKey.guiDashboardShortcut, defaultValue: SettingsKey.defaultGUIDashboardShortcut)
    }

    public func setGUIDashboardShortcut(_ raw: String?) throws {
        try store.setSetting(key: SettingsKey.guiDashboardShortcut, value: try normalizeLeaderBackedShortcut(raw))
    }

    public func guiAddProjectShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiAddProjectShortcut) ?? SettingsKey.defaultGUIAddProjectShortcut
    }

    public func setGUIAddProjectShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiAddProjectShortcut, value: raw) }

    public func guiAddWorkspaceShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiAddWorkspaceShortcut) ?? SettingsKey.defaultGUIAddWorkspaceShortcut
    }

    public func setGUIAddWorkspaceShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiAddWorkspaceShortcut, value: raw) }

    public func guiReloadShortcut() throws -> String {
        try effectiveLeaderBackedShortcut(settingKey: SettingsKey.guiReloadShortcut, defaultValue: SettingsKey.defaultGUIReloadShortcut)
    }

    public func setGUIReloadShortcut(_ raw: String?) throws {
        try store.setSetting(key: SettingsKey.guiReloadShortcut, value: try normalizeLeaderBackedShortcut(raw))
    }

    public func guiOpenEditorShortcut() throws -> String {
        try effectiveLeaderBackedShortcut(settingKey: SettingsKey.guiOpenEditorShortcut, defaultValue: SettingsKey.defaultGUIOpenEditorShortcut)
    }

    public func setGUIOpenEditorShortcut(_ raw: String?) throws {
        try store.setSetting(key: SettingsKey.guiOpenEditorShortcut, value: try normalizeLeaderBackedShortcut(raw))
    }

    public func guiOpenTerminalShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiOpenTerminalShortcut) ?? SettingsKey.defaultGUIOpenTerminalShortcut
    }

    public func setGUIOpenTerminalShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiOpenTerminalShortcut, value: raw) }

    public func guiOpenFinderShortcut() throws -> String {
        try effectiveLeaderBackedShortcut(settingKey: SettingsKey.guiOpenFinderShortcut, defaultValue: SettingsKey.defaultGUIOpenFinderShortcut)
    }

    public func setGUIOpenFinderShortcut(_ raw: String?) throws {
        try store.setSetting(key: SettingsKey.guiOpenFinderShortcut, value: try normalizeLeaderBackedShortcut(raw))
    }

    public func guiOpenSettingsShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiOpenSettingsShortcut) ?? SettingsKey.defaultGUIOpenSettingsShortcut
    }

    public func setGUIOpenSettingsShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiOpenSettingsShortcut, value: raw) }

    public func guiNextShortcut() throws -> String {
        try effectiveLeaderBackedShortcut(settingKey: SettingsKey.guiNextShortcut, defaultValue: SettingsKey.defaultGUINextShortcut)
    }

    public func setGUINextShortcut(_ raw: String?) throws {
        try store.setSetting(key: SettingsKey.guiNextShortcut, value: try normalizeLeaderBackedShortcut(raw))
    }

    public func guiPreviousShortcut() throws -> String {
        try effectiveLeaderBackedShortcut(settingKey: SettingsKey.guiPreviousShortcut, defaultValue: SettingsKey.defaultGUIPreviousShortcut)
    }

    public func setGUIPreviousShortcut(_ raw: String?) throws {
        try store.setSetting(key: SettingsKey.guiPreviousShortcut, value: try normalizeLeaderBackedShortcut(raw))
    }

    public func guiWindowShortcut() throws -> String { try store.setting(key: SettingsKey.guiWindowShortcut) ?? SettingsKey.defaultGUIWindowShortcut }

    public func setGUIWindowShortcut(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiWindowShortcut, value: raw) }

    public func guiWindowSequenceShortcut() throws -> String {
        try effectiveLeaderBackedShortcut(
            settingKey: SettingsKey.guiWindowSequenceShortcut, defaultValue: SettingsKey.defaultGUIWindowSequenceShortcut)
    }

    public func setGUIWindowSequenceShortcut(_ raw: String?) throws {
        try store.setSetting(key: SettingsKey.guiWindowSequenceShortcut, value: try normalizeLeaderBackedShortcut(raw))
    }

    public func dashboardDismissedAttentionItemIDs() throws -> Set<String> {
        guard let raw = try store.setting(key: SettingsKey.dashboardDismissedAttentionItems), !raw.isEmpty else { return [] }
        guard let data = raw.data(using: .utf8) else { return [] }
        let decoded = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return Set(decoded)
    }

    public func setDashboardDismissedAttentionItemIDs(_ ids: Set<String>) throws {
        guard !ids.isEmpty else {
            try store.setSetting(key: SettingsKey.dashboardDismissedAttentionItems, value: nil)
            return
        }
        let encoded = try JSONEncoder().encode(ids.sorted())
        try store.setSetting(key: SettingsKey.dashboardDismissedAttentionItems, value: String(decoding: encoded, as: UTF8.self))
    }

    private func guiLeaderModifiers() throws -> Set<HotkeyModifier> {
        if let raw = try store.setting(key: SettingsKey.guiLeaderHotkey), let modifiers = try? HotkeySpec.parseModifierSet(raw), !modifiers.isEmpty {
            return modifiers
        }
        return try HotkeySpec.parseModifierSet(SettingsKey.defaultGUILeaderHotkey)
    }

    private func effectiveLeaderBackedShortcut(settingKey: String, defaultValue: String) throws -> String {
        let leaderModifiers = try guiLeaderModifiers()
        guard let raw = try store.setting(key: settingKey), let stored = try? HotkeySpec.parse(raw) else {
            let spec = (try? HotkeySpec.parse(defaultValue)) ?? HotkeySpec(key: defaultValue, modifiers: [])
            return spec.adding(modifiers: leaderModifiers).normalized
        }
        if stored.modifiers.isEmpty { return stored.adding(modifiers: leaderModifiers).normalized }
        if stored.modifiers.isSuperset(of: leaderModifiers) {
            return stored.removing(modifiers: leaderModifiers).adding(modifiers: leaderModifiers).normalized
        }
        return stored.normalized
    }

    private func normalizeLeaderBackedShortcut(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let spec = try HotkeySpec.parse(raw)
        let leaderModifiers = try guiLeaderModifiers()
        if spec.modifiers.isSuperset(of: leaderModifiers) { return spec.removing(modifiers: leaderModifiers).normalized }
        return spec.normalized
    }

    public func windowFocusPulseColor() throws -> (r: Int, g: Int, b: Int) {
        let raw = (try? store.setting(key: SettingsKey.windowFocusPulseColor)) ?? SettingsKey.defaultWindowFocusPulseColor
        let parts = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 else { return (r: 0, g: 0, b: 0) }
        return (r: parts[0], g: parts[1], b: parts[2])
    }

    public func setWindowFocusPulseColor(r: Int, g: Int, b: Int) throws {
        let clamped = (r: max(0, min(255, r)), g: max(0, min(255, g)), b: max(0, min(255, b)))
        try store.setSetting(key: SettingsKey.windowFocusPulseColor, value: "\(clamped.r),\(clamped.g),\(clamped.b)")
    }

    public func windowFocusPulseEnabled() throws -> Bool {
        let raw = try? store.setting(key: SettingsKey.windowFocusPulseEnabled)
        guard let raw else { return SettingsKey.defaultWindowFocusPulseEnabled }
        return raw != "0"
    }

    public func setWindowFocusPulseEnabled(_ enabled: Bool) throws {
        try store.setSetting(key: SettingsKey.windowFocusPulseEnabled, value: enabled ? "1" : "0")
    }

    private func defaultWindowFocusPulseColor() -> (r: Int, g: Int, b: Int) {
        let parts = SettingsKey.defaultWindowFocusPulseColor.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 3 else { return (r: 0, g: 0, b: 0) }
        return (r: parts[0], g: parts[1], b: parts[2])
    }

    /// Returns the set of iTerm2 session IDs that are currently alive.
    /// Returns nil if iTerm2 is not running or the query fails.
    public func liveItermSessionIDs() -> Set<String>? {
        guard let terminalAdapter = terminalAdapter(for: .iterm2) else { return nil }
        return try? Set(terminalAdapter.listLiveTrackingIdentities().compactMap(\.sessionID))
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
                    id: existing.id, projectID: project.id, title: existing.title, dir: existing.dir, dirname: existing.dirname,
                    branch: existing.branch, targetBranch: existing.targetBranch, isDefault: true, isArchived: false, isHidden: existing.isHidden,
                    isRunning: existing.isRunning, lastLaunchedAt: existing.lastLaunchedAt)
                try store.upsert(workspace: revived)
            }
            return
        }
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, title: "default", dir: project.dir, dirname: nil, branch: project.defaultBranch,
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
                    id: existing.id, projectID: project.id, title: existing.title, dir: existing.dir, dirname: existing.dirname,
                    branch: existing.branch, targetBranch: existing.targetBranch, isDefault: true, isArchived: false, isHidden: existing.isHidden,
                    isRunning: existing.isRunning, lastLaunchedAt: existing.lastLaunchedAt)
                try store.upsert(workspace: revived)
            }
            return
        }

        let worktreeRoot = try worktreeRoot(project: project)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let workspaceDir = worktreeRoot.appendingPathComponent(branch, isDirectory: true).path
        try git.createWorktree(path: project.dir, worktreePath: workspaceDir, branch: branch, targetBranch: branch)

        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, title: branch, dir: workspaceDir, dirname: branch, branch: branch, targetBranch: branch,
            isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil)
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
            browserSessions: try store.workspaceBrowserSessions(workspaceID: defaultWorkspace.id),
            agentLaunchers: try store.workspaceAgentLaunchers(workspaceID: defaultWorkspace.id))

        let previousTemplate = WorkspaceSettings(
            stopScript: previousRecord.stopScript, ports: previousRecord.ports, processes: previousRecord.processes,
            browserSessions: previousRecord.browserSessions, agentLaunchers: previousRecord.agentLaunchers)

        guard workspaceSettingsMatch(currentSettings, previousTemplate) else { return }

        try seedWorkspaceSettings(project: updatedRecord, workspace: defaultWorkspace)
    }

    private func workspaceSettingsMatch(_ lhs: WorkspaceSettings, _ rhs: WorkspaceSettings) -> Bool {
        guard lhs.stopScript == rhs.stopScript else { return false }
        guard lhs.ports == rhs.ports else { return false }
        guard processTemplatesMatch(lhs.processes, rhs.processes) else { return false }
        guard browserSessionsMatch(lhs.browserSessions, rhs.browserSessions) else { return false }
        guard lhs.agentLaunchers == rhs.agentLaunchers else { return false }
        return true
    }

    private func normalizePortDefinitionIDs(previous: [PortDefinition], updated: [PortDefinition]) -> [PortDefinition] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let previousNameCounts = Dictionary(previous.map { ($0.name, 1) }, uniquingKeysWith: +)
        var usedIDs = Set<String>()

        return updated.map { definition in
            if previousByID[definition.id] != nil {
                usedIDs.insert(definition.id)
                return definition
            }
            guard previousNameCounts[definition.name] == 1,
                let match = previous.first(where: { $0.name == definition.name && !usedIDs.contains($0.id) })
            else { return definition }
            usedIDs.insert(match.id)
            return PortDefinition(id: match.id, name: definition.name)
        }
    }

    private func normalizeProcessTemplateIDs(previous: [ProcessTemplate], updated: [ProcessTemplate]) -> [ProcessTemplate] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let previousNames = previous.compactMap { template -> String? in
            let trimmed = template.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let previousCommands = previous.map { $0.command.trimmingCharacters(in: .whitespacesAndNewlines) }
        let nameCounts = Dictionary(previousNames.map { ($0, 1) }, uniquingKeysWith: +)
        let commandCounts = Dictionary(previousCommands.map { ($0, 1) }, uniquingKeysWith: +)
        var usedIDs = Set<String>()

        return updated.map { template in
            if previousByID[template.id] != nil {
                usedIDs.insert(template.id)
                return template
            }

            let trimmedName = template.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedName.isEmpty, nameCounts[trimmedName] == 1,
                let match = previous.first(where: {
                    ($0.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == trimmedName && !usedIDs.contains($0.id)
                })
            {
                usedIDs.insert(match.id)
                return ProcessTemplate(id: match.id, name: template.name, command: template.command, kind: template.kind, onExit: template.onExit)
            }

            let trimmedCommand = template.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty, commandCounts[trimmedCommand] == 1,
                let match = previous.first(where: {
                    $0.command.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedCommand && !usedIDs.contains($0.id)
                })
            {
                usedIDs.insert(match.id)
                return ProcessTemplate(id: match.id, name: template.name, command: template.command, kind: template.kind, onExit: template.onExit)
            }

            return template
        }
    }

    private func processTemplatesMatch(_ lhs: [ProcessTemplate], _ rhs: [ProcessTemplate]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            if left.name != right.name || left.command != right.command || left.kind != right.kind || left.onExit != right.onExit { return false }
        }
        return true
    }

    private func browserSessionsMatch(_ lhs: [BrowserSession], _ rhs: [BrowserSession]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) where left.name != right.name || left.url != right.url { return false }
        return true
    }

    private func seedWorkspaceSettings(project: ProjectRecord, workspace: WorkspaceRecord) throws {
        try validateWorkspaceFocusNames(
            workspaceID: workspace.id, processes: project.processes, browserSessions: project.browserSessions, agentLaunchers: project.agentLaunchers,
            agentWindows: try store.agentWindows(workspaceID: workspace.id))
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: project.stopScript)
        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: project.ports)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: project.processes)
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: project.browserSessions)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: project.agentLaunchers)
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
        let browserSessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        let agentLaunchers = try store.workspaceAgentLaunchers(workspaceID: workspace.id)
        return WorkspaceSettings(
            stopScript: stopScript, ports: ports, processes: processes, browserSessions: browserSessions, agentLaunchers: agentLaunchers)
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
                workspaceID: workspace.id, status: .succeeded, errorMessage: nil, startedAt: startedAt, finishedAt: nowISO8601())
            return
        }
        do {
            let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
            let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
            try runScript(applyEnvVars(setupScript, env: env), cwd: workspace.dir)
            try store.setWorkspaceSetupState(
                workspaceID: workspace.id, status: .succeeded, errorMessage: nil, startedAt: startedAt, finishedAt: nowISO8601())
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try store.setWorkspaceSetupState(
                workspaceID: workspace.id, status: .failed, errorMessage: message, startedAt: startedAt, finishedAt: nowISO8601())
            throw error
        }
    }

    private func waitForWorkspaceSetupToComplete(workspaceID: String) throws {
        let waitStartedAt = currentDate()
        while true {
            let setupState = try workspaceSetupState(workspaceID: workspaceID)
            switch setupState.status {
            case .succeeded: return
            case .failed:
                let detail = setupState.errorMessage?.isEmpty == false ? setupState.errorMessage! : "unknown setup error"
                throw MuxyError.invalidArgument(message: "Workspace setup failed: \(detail)")
            case .pending, .running:
                if currentDate().timeIntervalSince(waitStartedAt) > 900 {
                    throw MuxyError.invalidArgument(
                        message:
                            "Timed out waiting for workspace setup to finish. Retry launch after setup completes or run mx workspace up --restart.")
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

    private func processKey(for template: ProcessTemplate) -> String {
        let name = template.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = template.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? command : name
    }

    private struct RunningWorkspaceProcessEdit {
        let previous: ProcessTemplate
        let updated: ProcessTemplate
        let previousKey: String
        let updatedKey: String

        var commandChanged: Bool { previous.command != updated.command }
        var keyChanged: Bool { previousKey != updatedKey }
    }

    private func runningWorkspaceProcessEdits(previous: [ProcessTemplate], updated: [ProcessTemplate]) -> [RunningWorkspaceProcessEdit] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        return updated.compactMap { updatedTemplate in
            guard let previousTemplate = previousByID[updatedTemplate.id] else { return nil }
            let previousKey = processKey(for: previousTemplate)
            let updatedKey = processKey(for: updatedTemplate)
            let edit = RunningWorkspaceProcessEdit(
                previous: previousTemplate, updated: updatedTemplate, previousKey: previousKey, updatedKey: updatedKey)
            guard edit.commandChanged || edit.keyChanged else { return nil }
            return edit
        }
    }

    private func applyRunningWorkspaceProcessEdits(
        project: ProjectRecord, workspace: WorkspaceRecord, previous: [ProcessTemplate], updated: [ProcessTemplate], restartChangedCommands: Bool
    ) throws {
        let edits = runningWorkspaceProcessEdits(previous: previous, updated: updated)
        let commandChangedEdits = edits.filter(\.commandChanged)
        if !commandChangedEdits.isEmpty, !restartChangedCommands {
            throw MuxyError.invalidArgument(message: "Changing a running process command requires restart confirmation.")
        }

        let runningProcesses = try store.runningProcesses(workspaceID: workspace.id)
        let runningByKey = Dictionary(uniqueKeysWithValues: runningProcesses.map { ($0.templateName, $0) })

        if !commandChangedEdits.isEmpty {
            for edit in commandChangedEdits {
                guard let runningProcess = runningByKey[edit.previousKey] else { continue }
                try validateRunningProcessRestart(project: project, workspace: workspace, process: runningProcess, updatedTemplate: edit.updated)
            }
        }

        for edit in edits {
            guard let runningProcess = runningByKey[edit.previousKey] else { continue }
            if edit.commandChanged {
                let restartedProcess = RunningProcessRecord(
                    id: runningProcess.id, workspaceID: runningProcess.workspaceID, templateName: edit.updatedKey, command: edit.updated.command,
                    terminalApp: runningProcess.terminalApp, windowID: runningProcess.windowID, terminalTrackingID: runningProcess.terminalTrackingID,
                    terminalNativeID: runningProcess.terminalNativeID, itermTabIndex: runningProcess.itermTabIndex,
                    tmuxWindowID: runningProcess.tmuxWindowID, pid: runningProcess.pid, status: runningProcess.status,
                    logPath: runningProcess.logPath, lastOutputAt: runningProcess.lastOutputAt, startedAt: runningProcess.startedAt,
                    exitedAt: runningProcess.exitedAt)
                try restartProcessInTerminal(workspaceID: workspace.id, process: restartedProcess)
            } else if edit.keyChanged {
                try relabelRunningProcess(
                    workspaceID: workspace.id, process: runningProcess, templateName: edit.updatedKey, command: runningProcess.command)
            }
        }
    }

    private func validateRunningProcessRestart(
        project: ProjectRecord, workspace: WorkspaceRecord, process: RunningProcessRecord, updatedTemplate: ProcessTemplate
    ) throws {
        let terminalHost = try terminalHost(for: process.terminalApp) ?? configuredTerminalHost()
        guard terminalAdapterAvailable(terminalHost) else {
            throw MuxyError.dependencyMissing(message: missingTerminalDependencyMessage(for: terminalHost, operation: "launch processes"))
        }
        guard tmux.isAvailable() else { throw MuxyError.dependencyMissing(message: "tmux is required to launch processes.") }
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        guard parseDirectProcessCommand(updatedTemplate.command, env: env) != nil else {
            throw MuxyError.invalidArgument(message: invalidDirectProcessCommandMessage(updatedTemplate.command, env: env))
        }
    }

    private func relabelRunningProcess(workspaceID: String, process: RunningProcessRecord, templateName: String, command: String) throws {
        let updatedProcess = RunningProcessRecord(
            id: process.id, workspaceID: process.workspaceID, templateName: templateName, command: command, terminalApp: process.terminalApp,
            windowID: process.windowID, terminalTrackingID: process.terminalTrackingID, terminalNativeID: process.terminalNativeID,
            itermTabIndex: process.itermTabIndex, tmuxWindowID: process.tmuxWindowID, pid: process.pid, status: process.status,
            logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: process.exitedAt)
        try store.upsert(runningProcess: updatedProcess)
        if let terminalWindow = try store.windows(workspaceID: workspaceID).first(where: {
            $0.role == "terminal"
                && (($0.windowID != nil && $0.windowID == process.windowID) || ($0.tmuxWindowID != nil && $0.tmuxWindowID == process.tmuxWindowID))
        }) {
            try store.upsert(
                window: WindowRecord(
                    id: terminalWindow.id, workspaceID: terminalWindow.workspaceID, app: terminalWindow.app, name: templateName, detail: command,
                    targetURL: terminalWindow.targetURL, windowID: terminalWindow.windowID, terminalTrackingID: terminalWindow.terminalTrackingID,
                    terminalNativeID: terminalWindow.terminalNativeID, itermTabIndex: terminalWindow.itermTabIndex,
                    tmuxWindowID: terminalWindow.tmuxWindowID, role: terminalWindow.role, orderIndex: terminalWindow.orderIndex,
                    lastSeenAt: nowISO8601()))
        }
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
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })

        var desiredByMatch: [String: DesiredProcess] = [:]
        for template in updated {
            let desiredKey = processKey(for: template)
            let matchKey = previousByID[template.id].map(processKey(for:)) ?? desiredKey
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

        let terminalHost = try configuredTerminalHost()
        if !toStart.isEmpty || !toRestart.isEmpty, !terminalAdapterAvailable(terminalHost) {
            throw MuxyError.dependencyMissing(message: missingTerminalDependencyMessage(for: terminalHost, operation: "launch processes"))
        }

        for process in toStop {
            if let pid = resolvedRuntimePID(for: process) { terminateProcessGroup(pid: pid) }
            if isManagedTerminalApp(process.terminalApp) { _ = try? closeTrackedItermTerminalContainer(process) }
            try store.deleteRunningProcess(id: process.id)
            if let terminalWindow = try store.windows(workspaceID: workspace.id).first(where: {
                ($0.windowID != nil && $0.windowID == process.windowID) || ($0.tmuxWindowID != nil && $0.tmuxWindowID == process.tmuxWindowID)
            }) {
                try store.deleteWindow(id: terminalWindow.id)
            }
        }

        for (desired, process) in toRelabel {
            let updated = RunningProcessRecord(
                id: process.id, workspaceID: workspace.id, templateName: desired.desiredKey, command: process.command,
                terminalApp: process.terminalApp, windowID: process.windowID, terminalTrackingID: process.terminalTrackingID,
                terminalNativeID: process.terminalNativeID, itermTabIndex: process.itermTabIndex, tmuxWindowID: process.tmuxWindowID,
                pid: process.pid, status: process.status, logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt,
                exitedAt: process.exitedAt)
            try store.upsert(runningProcess: updated)
            if let terminalWindow = try store.windows(workspaceID: workspace.id).first(where: {
                $0.role == "terminal"
                    && (($0.windowID != nil && $0.windowID == process.windowID)
                        || ($0.tmuxWindowID != nil && $0.tmuxWindowID == process.tmuxWindowID))
            }) {
                try store.upsert(
                    window: WindowRecord(
                        id: terminalWindow.id, workspaceID: terminalWindow.workspaceID, app: terminalWindow.app, name: desired.desiredKey,
                        detail: updated.command, targetURL: terminalWindow.targetURL, windowID: terminalWindow.windowID,
                        terminalTrackingID: terminalWindow.terminalTrackingID, terminalNativeID: terminalWindow.terminalNativeID,
                        itermTabIndex: terminalWindow.itermTabIndex, tmuxWindowID: terminalWindow.tmuxWindowID, role: terminalWindow.role,
                        orderIndex: terminalWindow.orderIndex, lastSeenAt: nowISO8601()))
            }
        }

        for (desired, process) in toRestart {
            let name = desired.desiredKey
            let updatedProcess = RunningProcessRecord(
                id: process.id, workspaceID: process.workspaceID, templateName: name, command: desired.template.command,
                terminalApp: process.terminalApp, windowID: process.windowID, terminalTrackingID: process.terminalTrackingID,
                terminalNativeID: process.terminalNativeID, itermTabIndex: process.itermTabIndex, tmuxWindowID: process.tmuxWindowID,
                pid: process.pid, status: process.status, logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt,
                exitedAt: process.exitedAt)
            try restartProcessInTerminal(workspaceID: workspace.id, process: updatedProcess)
        }

        for (_, desired) in toStart.sorted(by: { $0.value.desiredKey.localizedStandardCompare($1.value.desiredKey) == .orderedAscending }) {
            _ = try launchConfiguredProcess(template: desired.template, workspace: workspace, env: env, terminalHost: terminalHost)
        }
    }

    private func reconcileBrowserSessions(project: ProjectRecord, workspace: WorkspaceRecord, sessions: [BrowserSession], env: [String: String])
        throws
    {
        _ = project
        let tracked = try store.windows(workspaceID: workspace.id).filter { $0.role == "browser" }
        let resolvedSessions = resolveBrowserSessions(sessions, env: env)
        if resolvedSessions.isEmpty {
            for window in tracked {
                closeTrackedBrowserTab(window)
                try store.deleteWindow(id: window.id)
            }
            return
        }
        let desiredOrderByTargetURL = Dictionary(uniqueKeysWithValues: resolvedSessions.map { ($0.prefix, $0.index) })
        for window in tracked {
            guard let targetURL = window.targetURL, let desiredOrder = desiredOrderByTargetURL[targetURL] else {
                if window.windowID != nil { closeTrackedBrowserTab(window) }
                try store.deleteWindow(id: window.id)
                continue
            }
            if window.orderIndex != desiredOrder {
                try store.upsert(
                    window: WindowRecord(
                        id: window.id, workspaceID: window.workspaceID, app: window.app, name: window.name, detail: window.detail,
                        targetURL: targetURL, windowID: window.windowID, terminalTrackingID: window.terminalTrackingID,
                        terminalNativeID: window.terminalNativeID, itermTabIndex: window.itermTabIndex, tmuxWindowID: window.tmuxWindowID,
                        role: window.role, orderIndex: desiredOrder, lastSeenAt: window.lastSeenAt))
            }
        }
    }

    @discardableResult private func pruneMissingWindows(workspaceID: String) throws -> Int {
        let existingIDs = Set(try yabai.listWindows().map(\.id))
        let windows = try store.windows(workspaceID: workspaceID)
        let liveTmuxWindowIDs = Set(try tmuxWindows(workspaceID: workspaceID).map(\.id))
        let liveGhosttyTrackingIdentities = (try? ghostty.listLiveTrackingIdentities()) ?? []
        var prunedTerminalTrackingKeys = Set<String>()
        var prunedTerminalWindowIDs = Set<Int>()
        var pruned = 0
        for window in windows {
            guard let id = window.windowID else {
                if ghosttyTrackedWindowIsStillLive(window: window, liveGhosttyTrackingIdentities: liveGhosttyTrackingIdentities) { continue }
                if let tmuxWindowID = window.tmuxWindowID, liveTmuxWindowIDs.contains(tmuxWindowID) { continue }
                if window.role == "terminal", let trackingKey = window.terminalTrackingKey { prunedTerminalTrackingKeys.insert(trackingKey) }
                try store.deleteWindow(id: window.id)
                pruned += 1
                continue
            }
            if !existingIDs.contains(id) {
                if ghosttyTrackedWindowIsStillLive(window: window, liveGhosttyTrackingIdentities: liveGhosttyTrackingIdentities) { continue }
                if window.role == "browser" { continue }
                if let tmuxWindowID = window.tmuxWindowID, liveTmuxWindowIDs.contains(tmuxWindowID) { continue }
                if window.role == "terminal" {
                    prunedTerminalWindowIDs.insert(id)
                    if let trackingKey = window.terminalTrackingKey { prunedTerminalTrackingKeys.insert(trackingKey) }
                }
                try store.deleteWindow(id: window.id)
                pruned += 1
            }
        }
        pruned += try pruneOrphanedAgentWindows(
            workspaceID: workspaceID, prunedTerminalTrackingKeys: prunedTerminalTrackingKeys, prunedTerminalWindowIDs: prunedTerminalWindowIDs)
        return pruned
    }

    private func ghosttyTrackedWindowIsStillLive(window: WindowRecord, liveGhosttyTrackingIdentities: Set<TerminalTrackingIdentity>) -> Bool {
        guard window.role == "terminal", terminalHost(for: window.app) == .ghostty, let terminalID = window.terminalNativeID, !terminalID.isEmpty
        else { return false }
        return liveGhosttyTrackingIdentities.contains(.session(terminalID))
    }

    @discardableResult private func pruneOrphanedAgentWindows(
        workspaceID: String, prunedTerminalTrackingKeys: Set<String>, prunedTerminalWindowIDs: Set<Int>
    ) throws -> Int {
        guard !prunedTerminalTrackingKeys.isEmpty || !prunedTerminalWindowIDs.isEmpty else { return 0 }
        let runningProcessTrackingKeys = Set(try store.runningProcesses(workspaceID: workspaceID).compactMap(\.terminalTrackingKey))
        var pruned = 0
        for agent in try store.agentWindows(workspaceID: workspaceID) where TerminalHost(rawValue: agent.provider.rawValue) != nil {
            if let tmuxWindowID = agent.tmuxWindowID, !tmuxWindowID.isEmpty { continue }
            let trackingKey = agent.terminalTrackingKey
            let windowID = agent.yabaiWindowID ?? agent.windowID
            // Agent rows for ad-hoc terminals depend on the tracked terminal row for liveness.
            // Once that terminal disappears, the agent row should disappear too unless a managed
            // workspace process still owns the same terminal identity.
            let matchesPrunedTerminal =
                (trackingKey.map(prunedTerminalTrackingKeys.contains) ?? false) || (windowID.map(prunedTerminalWindowIDs.contains) ?? false)
            guard matchesPrunedTerminal else { continue }
            if let trackingKey, runningProcessTrackingKeys.contains(trackingKey) { continue }
            try store.deleteAgentWindow(id: agent.id)
            pruned += 1
        }
        return pruned
    }

    private func windowTrackingKey(_ window: WindowRecord) -> String {
        let idPart = window.windowID.map(String.init) ?? "none"
        if window.role == "browser" { return "browser:\(idPart):\(window.targetURL ?? "")" }
        return "\(window.role):\(idPart)"
    }

    private func closeTrackedBrowserTab(_ window: WindowRecord) {
        guard window.role == "browser" else { return }
        guard let trackedWindowID = window.windowID else { return }
        _ = try? yabai.closeWindow(id: trackedWindowID)
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
        var seenWindowIDs = Set(existingWindows.compactMap(\.windowID))
        var synthesized: [WindowRecord] = []
        for process in processRecords where isManagedTerminalApp(process.terminalApp) {
            guard let windowID = process.windowID, !seenWindowIDs.contains(windowID) else { continue }
            seenWindowIDs.insert(windowID)
            synthesized.append(
                WindowRecord(
                    id: UUID().uuidString, workspaceID: workspace.id, app: process.terminalApp ?? TerminalHost.iterm2.appName,
                    name: process.templateName, detail: process.command, windowID: windowID, terminalTrackingID: process.terminalTrackingID,
                    itermTabIndex: nil, tmuxWindowID: process.tmuxWindowID, role: "terminal", orderIndex: 200 + synthesized.count,
                    lastSeenAt: nowISO8601()))
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
                    id: UUID().uuidString, workspaceID: workspaceID, app: focused.app, name: focused.title, detail: focused.title,
                    windowID: focused.id, role: role, orderIndex: orderOffset, lastSeenAt: nowISO8601())
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
                id: window.id, workspaceID: workspaceID, app: window.app, name: window.name, detail: window.detail, windowID: id, role: role,
                orderIndex: nextIndex, lastSeenAt: nowISO8601())
            nextIndex += 1
            try store.upsert(window: stored)
        }
    }

    private func launchProcesses(workspace: WorkspaceRecord, templates: [ProcessTemplate], env: [String: String], background: Bool = false) throws
        -> [WindowRecord]
    {
        guard !templates.isEmpty else {
            try store.deleteRunningProcesses(workspaceID: workspace.id)
            return []
        }
        let terminalHost = try configuredTerminalHost()
        guard terminalAdapterAvailable(terminalHost) else {
            throw MuxyError.dependencyMissing(message: missingTerminalDependencyMessage(for: terminalHost, operation: "launch processes"))
        }
        guard tmux.isAvailable() else { throw MuxyError.dependencyMissing(message: "tmux is required to launch processes.") }
        try store.deleteRunningProcesses(workspaceID: workspace.id)
        var terminalWindows: [WindowRecord] = []
        for (index, template) in templates.enumerated() {
            let name = template.name ?? template.command
            guard let command = parseDirectProcessCommand(template.command, env: env) else {
                throw MuxyError.invalidArgument(message: invalidDirectProcessCommandMessage(template.command, env: env))
            }
            let snapshot = bestEffortYabaiWindowSnapshot()
            let terminalHandle = try launchProcessInTmux(
                workspace: workspace, processName: name, rawCommand: template.command, command: command, env: env, terminalHost: terminalHost,
                background: background, replaceExistingSession: true)
            let windowID =
                bestEffortCaptureNewAppWindowID(snapshot: snapshot, appName: terminalAppName(for: terminalHost)) ?? terminalHandle.fallbackWindowID
            let tmuxWindow = try currentTmuxWindowInfo(workspaceID: workspace.id, processName: name)
            let pid = tmuxWindow?.panePID
            let hookSessionID = storedTerminalHookSessionID(terminalHost: terminalHost, handle: terminalHandle)
            let terminalNativeID = storedTerminalNativeID(terminalHost: terminalHost, handle: terminalHandle)
            let running = RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: name, command: template.command,
                terminalApp: terminalAppName(for: terminalHost), windowID: windowID, terminalTrackingID: hookSessionID,
                terminalNativeID: terminalNativeID, itermTabIndex: nil, tmuxWindowID: tmuxWindow?.id, pid: pid, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: nowISO8601(), exitedAt: nil)
            try store.upsert(runningProcess: running)
            terminalWindows.append(
                WindowRecord(
                    id: UUID().uuidString, workspaceID: workspace.id, app: terminalAppName(for: terminalHost), name: name, detail: template.command,
                    targetURL: nil, windowID: windowID, terminalTrackingID: hookSessionID, terminalNativeID: terminalNativeID, itermTabIndex: nil,
                    tmuxWindowID: tmuxWindow?.id, role: "terminal", orderIndex: 200 + index, lastSeenAt: nowISO8601()))
        }
        return terminalWindows
    }

    private func ensureBrowserSessions(
        project: ProjectRecord, workspace: WorkspaceRecord, sessions: [BrowserSession], env: [String: String], extractOnAttach: Bool,
        background: Bool = false
    ) throws -> (windows: [WindowRecord], sessions: [BrowserSession]) {
        _ = project
        _ = extractOnAttach
        guard !sessions.isEmpty else { return ([], []) }
        guard chrome.isAvailable() else { throw MuxyError.dependencyMissing(message: "Google Chrome is required for browser sessions.") }
        let resolvedSessions = resolveBrowserSessions(sessions, env: env)
        var attached: [WindowRecord] = []
        var refreshedSessions = sessions
        for resolvedSession in resolvedSessions {
            if let extractedWindow = refreshedSessions[resolvedSession.index].extractedWindow, extractedWindow.isValid,
                let liveWindow = try yabai.listWindows().first(where: { $0.id == extractedWindow.windowID && $0.app == "Google Chrome" })
            {
                attached.append(
                    WindowRecord(
                        id: UUID().uuidString, workspaceID: workspace.id, app: liveWindow.app,
                        name: try browserFocusName(workspaceID: workspace.id, targetURL: resolvedSession.prefix) ?? resolvedSession.prefix,
                        detail: resolvedSession.prefix, targetURL: resolvedSession.prefix, windowID: liveWindow.id, role: "browser",
                        orderIndex: attached.count, lastSeenAt: nowISO8601()))
                continue
            }

            let snapshot = try yabai.listWindows()
            _ = try chrome.openWindow(url: resolvedSession.prefix, background: background)
            guard let newWindow = try captureNewAppWindow(snapshot: snapshot, appName: "Google Chrome") else { continue }
            refreshedSessions[resolvedSession.index].extractedWindow = ExtractedBrowserWindowMapping(
                targetURL: resolvedSession.prefix, windowID: newWindow.id, isValid: true)
            attached.append(
                WindowRecord(
                    id: UUID().uuidString, workspaceID: workspace.id, app: newWindow.app,
                    name: try browserFocusName(workspaceID: workspace.id, targetURL: resolvedSession.prefix) ?? resolvedSession.prefix,
                    detail: resolvedSession.prefix, targetURL: resolvedSession.prefix, windowID: newWindow.id, role: "browser",
                    orderIndex: attached.count, lastSeenAt: nowISO8601()))
        }
        return (attached, refreshedSessions)
    }

    private func captureNewWindows(snapshot: [YabaiWindow], role: String, appName: String, workspaceID: String, orderOffset: Int) throws
        -> [WindowRecord]
    { try captureNewWindows(snapshot: snapshot, role: role, appNames: [appName], workspaceID: workspaceID, orderOffset: orderOffset) }

    private func captureNewAppWindow(snapshot: [YabaiWindow], appName: String) throws -> YabaiWindow? {
        let previousIDs = Set(snapshot.map(\.id))
        let current = try yabai.listWindows()
        if let created = current.first(where: { $0.app == appName && !previousIDs.contains($0.id) }) { return created }
        if let focused = try yabai.focusedWindow(), focused.app == appName { return focused }
        return current.filter { $0.app == appName }.sorted { $0.id > $1.id }.first
    }

    private func captureNewAppWindowID(snapshot: [YabaiWindow], appName: String) throws -> Int? {
        try captureNewAppWindow(snapshot: snapshot, appName: appName)?.id
    }

    private func bestEffortYabaiWindowSnapshot() -> [YabaiWindow] { (try? yabai.listWindows()) ?? [] }

    private func bestEffortCaptureNewAppWindowID(snapshot: [YabaiWindow], appName: String) -> Int? {
        try? captureNewAppWindowID(snapshot: snapshot, appName: appName)
    }

    private func openDedicatedItermWindow(command: String, background: Bool = false) throws -> ItermWindowInfo {
        try iterm.openWindowAndRun(command: command, background: background)
    }

    private func captureNewWindows(snapshot: [YabaiWindow], role: String, appNames: Set<String>, workspaceID: String, orderOffset: Int) throws
        -> [WindowRecord]
    {
        let after = try yabai.listWindows()
        let snapshotIDs = Set(snapshot.map(\.id))
        let created = after.filter { !snapshotIDs.contains($0.id) && appNames.contains($0.app) }
        return created.enumerated().map { idx, win in
            WindowRecord(
                id: UUID().uuidString, workspaceID: workspaceID, app: win.app, name: win.title, detail: win.title, windowID: win.id, role: role,
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
        if let tmuxRuntimePID = resolvedTmuxRuntimePID(for: process) { return tmuxRuntimePID }
        if let pid = process.pid, pid > 0 {
            if isProcessAlive(pid: pid) { return pid }
            guard isManagedTerminalApp(process.terminalApp) else { return pid }
            guard let pidFile = try? processRuntimePaths(workspaceID: process.workspaceID, name: process.templateName).pidFile else { return pid }
            if let runtimePID = runtimePID(fromFile: pidFile), runtimePID > 0, isProcessAlive(pid: runtimePID) { return runtimePID }
            return pid
        }
        guard isManagedTerminalApp(process.terminalApp) else { return nil }
        guard let pidFile = try? processRuntimePaths(workspaceID: process.workspaceID, name: process.templateName).pidFile else { return nil }
        return runtimePID(fromFile: pidFile)
    }

    private func resolvedTmuxRuntimePID(for process: RunningProcessRecord) -> Int? {
        guard isManagedTerminalApp(process.terminalApp) else { return nil }
        let sessionName = processTmuxSessionName(workspaceID: process.workspaceID, processName: process.templateName)
        guard let tmuxWindow = try? tmux.currentWindow(sessionName: sessionName), let panePID = tmuxWindow.panePID, panePID > 0,
            isProcessAlive(pid: panePID)
        else { return nil }
        return panePID
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

    private func isManagedRepositoryDirectory(path: String) -> Bool { isPath(path, inside: repositoriesRootDirectory().path) }

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

    private func matchingAgentWindow(
        workspaceID: String, tmuxWindowID: String?, terminalTrackingID: String?, codexThreadID: String?, yabaiWindowID: Int?
    ) throws -> AgentWindowRecord? {
        let allAgentWindows = try store.agentWindows(workspaceID: workspaceID)
        return tmuxWindowID.flatMap { tmuxWindowID in allAgentWindows.first(where: { $0.tmuxWindowID == tmuxWindowID }) }
            ?? terminalTrackingID.flatMap { sessionID in allAgentWindows.first(where: { $0.terminalTrackingID == sessionID }) }
            ?? yabaiWindowID.flatMap { windowID in allAgentWindows.first(where: { ($0.yabaiWindowID ?? $0.windowID) == windowID }) }
            ?? allAgentWindows.first(where: { $0.codexThreadID == codexThreadID && codexThreadID != nil })
    }

    private func agentTerminalTargetID(terminalTrackingID: String?, yabaiWindowID: Int?, tmuxWindowID: String?) -> String? {
        if let tmuxWindowID, !tmuxWindowID.isEmpty { return "tmux:\(tmuxWindowID)" }
        if let sessionID = terminalTrackingID, !sessionID.isEmpty { return "terminal:\(sessionID)" }
        if let windowID = yabaiWindowID { return "window:\(windowID)" }
        return nil
    }

    private func matchedWorkspaceProcessForAgent(
        workspaceID: String, provider: AgentProvider, terminalTrackingID: String?, yabaiWindowID: Int?, tmuxWindowID: String?
    ) throws -> RunningProcessRecord? {
        let processes = try store.runningProcesses(workspaceID: workspaceID)
        let targetID = agentTerminalTargetID(terminalTrackingID: terminalTrackingID, yabaiWindowID: yabaiWindowID, tmuxWindowID: tmuxWindowID)
        if let targetID, let matched = processes.first(where: { $0.terminalTrackingKey == targetID }) { return matched }
        return processes.first(where: { process in
            guard terminalHost(for: process.terminalApp)?.rawValue == provider.rawValue else { return false }
            if let tmuxWindowID, !tmuxWindowID.isEmpty { return process.tmuxWindowID == tmuxWindowID }
            if let terminalTrackingID, !terminalTrackingID.isEmpty, process.terminalTrackingID == terminalTrackingID { return true }
            if let terminalTrackingID, !terminalTrackingID.isEmpty {
                guard process.terminalTrackingID == nil || process.terminalTrackingID?.isEmpty == true else { return false }
            }
            if let yabaiWindowID, process.windowID == yabaiWindowID { return true }
            return false
        })
    }

    private func matchedTrackedWindowForAgent(
        workspaceID: String, provider: AgentProvider, terminalTrackingID: String?, yabaiWindowID: Int?, tmuxWindowID: String?
    ) throws -> WindowRecord? {
        let windows = try store.windows(workspaceID: workspaceID)
        if let tmuxWindowID, !tmuxWindowID.isEmpty,
            let trackedWindow = windows.first(where: { $0.role == "terminal" && $0.tmuxWindowID == tmuxWindowID })
        {
            return trackedWindow
        }
        if provider == .ghostty, let terminalTrackingID, !terminalTrackingID.isEmpty,
            let trackedWindow = windows.first(where: {
                $0.role == "terminal" && $0.app == TerminalHost.ghostty.appName && $0.terminalTrackingID == terminalTrackingID
            })
        {
            return trackedWindow
        }
        if let targetID = agentTerminalTargetID(terminalTrackingID: terminalTrackingID, yabaiWindowID: yabaiWindowID, tmuxWindowID: tmuxWindowID),
            let trackedWindow = windows.first(where: { $0.role == "terminal" && $0.terminalTrackingKey == targetID })
        {
            return trackedWindow
        }
        if let yabaiWindowID,
            let trackedWindow = windows.first(where: {
                $0.role == "terminal" && $0.windowID == yabaiWindowID
                    && (terminalTrackingID == nil || terminalTrackingID?.isEmpty == true || $0.terminalTrackingID == nil
                        || $0.terminalTrackingID?.isEmpty == true)
                    && terminalHost(for: $0.app)?.rawValue == provider.rawValue
            })
        {
            return trackedWindow
        }
        return nil
    }

    private func ensureTrackedWindowExistsForAgent(
        workspaceID: String, provider: AgentProvider, label: String?, terminalTrackingID: String?, terminalNativeID: String?, yabaiWindowID: Int?,
        tmuxWindowID: String?
    ) throws -> WindowRecord? {
        if let trackedWindow = try matchedTrackedWindowForAgent(
            workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID, yabaiWindowID: yabaiWindowID,
            tmuxWindowID: tmuxWindowID)
        {
            let liveWindow = yabaiWindowID.flatMap { (try? yabai.window(id: $0)) ?? nil }
            let resolvedWindowID = yabaiWindowID ?? trackedWindow.windowID
            let resolvedSessionID = terminalTrackingID ?? trackedWindow.terminalTrackingID
            let resolvedNativeID = terminalNativeID ?? trackedWindow.terminalNativeID
            let resolvedTmuxWindowID = tmuxWindowID ?? trackedWindow.tmuxWindowID
            if resolvedWindowID != trackedWindow.windowID || resolvedSessionID != trackedWindow.terminalTrackingID
                || resolvedNativeID != trackedWindow.terminalNativeID || resolvedTmuxWindowID != trackedWindow.tmuxWindowID
            {
                let updated = WindowRecord(
                    id: trackedWindow.id, workspaceID: trackedWindow.workspaceID, app: liveWindow?.app ?? trackedWindow.app, name: trackedWindow.name,
                    detail: trackedWindow.detail, targetURL: trackedWindow.targetURL, windowID: resolvedWindowID,
                    terminalTrackingID: resolvedSessionID, terminalNativeID: resolvedNativeID, itermTabIndex: trackedWindow.itermTabIndex,
                    tmuxWindowID: resolvedTmuxWindowID, role: trackedWindow.role, orderIndex: trackedWindow.orderIndex, lastSeenAt: nowISO8601())
                try store.upsert(window: updated)
                return updated
            }
            return trackedWindow
        }
        guard let yabaiWindowID else { return nil }
        let liveWindow = (try? yabai.window(id: yabaiWindowID)) ?? nil
        let existing = try store.windows(workspaceID: workspaceID)
        let record = WindowRecord(
            id: UUID().uuidString, workspaceID: workspaceID,
            app: liveWindow?.app ?? (TerminalHost(rawValue: provider.rawValue)?.appName ?? provider.rawValue),
            name: liveWindow?.title ?? label ?? "Coding Agent CLI", detail: nil, windowID: yabaiWindowID, terminalTrackingID: terminalTrackingID,
            terminalNativeID: terminalNativeID, itermTabIndex: nil, tmuxWindowID: tmuxWindowID, role: "terminal",
            orderIndex: Self.nextWindowOrderIndex(existing: existing, role: "terminal", orderOffset: 200), lastSeenAt: nowISO8601())
        try store.upsert(window: record)
        return record
    }

    private func agentWindowIsOpen(_ windowID: Int?) -> Bool {
        guard let windowID, let liveWindow = (try? yabai.window(id: windowID)) ?? nil else { return false }
        return liveWindow.id == windowID
    }

    private func removeStaleAgentWindow(_ record: AgentWindowRecord) throws {
        try store.deleteAgentWindow(id: record.id)
        try removeAdHocTrackedWindowForAgent(
            workspaceID: record.workspaceID, provider: record.provider, terminalTrackingID: record.terminalTrackingID,
            yabaiWindowID: record.yabaiWindowID ?? record.windowID, tmuxWindowID: record.tmuxWindowID)
    }

    private func removeAdHocTrackedWindowForAgent(
        workspaceID: String, provider: AgentProvider, terminalTrackingID: String?, yabaiWindowID: Int?, tmuxWindowID: String?
    ) throws {
        guard tmuxWindowID == nil else { return }
        guard
            let trackedWindow = try matchedTrackedWindowForAgent(
                workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID, yabaiWindowID: yabaiWindowID,
                tmuxWindowID: tmuxWindowID)
        else { return }
        let processUsesWindow = try store.runningProcesses(workspaceID: workspaceID).contains { process in
            process.terminalTrackingKey == trackedWindow.terminalTrackingKey
        }
        if !processUsesWindow { try store.deleteWindow(id: trackedWindow.id) }
    }

    @discardableResult public func registerAgentWindow(
        workspaceID: String, provider: AgentProvider, label: String? = nil, terminalTrackingID: String? = nil, tmuxWindowID: String? = nil,
        terminalNativeID: String? = nil, codexThreadID: String? = nil, yabaiWindowID: Int? = nil, status: AgentWindowStatus = .idle,
        claimedLauncherName: String? = nil
    ) throws -> AgentWindowRecord {
        let now = nowISO8601()
        let existingAgentWindows = try store.agentWindows(workspaceID: workspaceID)
        let matchedProcess = try matchedWorkspaceProcessForAgent(
            workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID, yabaiWindowID: yabaiWindowID,
            tmuxWindowID: tmuxWindowID)
        let resolvedTmuxWindowID = tmuxWindowID ?? matchedProcess?.tmuxWindowID
        let resolvedTerminalNativeID = matchedProcess?.terminalNativeID ?? terminalNativeID
        let trackedWindow = try ensureTrackedWindowExistsForAgent(
            workspaceID: workspaceID, provider: provider, label: label, terminalTrackingID: terminalTrackingID,
            terminalNativeID: resolvedTerminalNativeID, yabaiWindowID: yabaiWindowID, tmuxWindowID: resolvedTmuxWindowID)
        let resolvedWindowID = trackedWindow?.windowID ?? yabaiWindowID
        let finalTerminalNativeID = trackedWindow?.terminalNativeID ?? resolvedTerminalNativeID
        if let existing = try matchingAgentWindow(
            workspaceID: workspaceID, tmuxWindowID: resolvedTmuxWindowID, terminalTrackingID: terminalTrackingID, codexThreadID: codexThreadID,
            yabaiWindowID: resolvedWindowID)
        {
            let resolvedLabel = try uniqueAgentFocusLabel(
                workspaceID: workspaceID, preferredLabel: label ?? existing.label, excludingAgentWindowID: existing.id,
                claimedLauncherName: claimedLauncherName ?? existing.label)
            let updated = AgentWindowRecord(
                id: existing.id, workspaceID: existing.workspaceID, provider: existing.provider, label: resolvedLabel,
                terminalTrackingID: terminalTrackingID ?? existing.terminalTrackingID,
                terminalNativeID: finalTerminalNativeID ?? existing.terminalNativeID, tmuxWindowID: resolvedTmuxWindowID ?? existing.tmuxWindowID,
                codexThreadID: codexThreadID ?? existing.codexThreadID, windowID: resolvedWindowID ?? existing.windowID,
                yabaiWindowID: resolvedWindowID ?? existing.yabaiWindowID, status: status, createdAt: existing.createdAt, updatedAt: now)
            try validateWorkspaceFocusNames(
                workspaceID: workspaceID, processes: try store.workspaceProcesses(workspaceID: workspaceID),
                browserSessions: try store.workspaceBrowserSessions(workspaceID: workspaceID),
                agentWindows: existingAgentWindows.map { $0.id == existing.id ? updated : $0 })
            try store.upsertAgentWindow(updated)
            return updated
        }
        let resolvedLabel = try uniqueAgentFocusLabel(workspaceID: workspaceID, preferredLabel: label, claimedLauncherName: claimedLauncherName)
        let record = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspaceID, provider: provider, label: resolvedLabel, terminalTrackingID: terminalTrackingID,
            terminalNativeID: finalTerminalNativeID, tmuxWindowID: resolvedTmuxWindowID, codexThreadID: codexThreadID, windowID: resolvedWindowID,
            yabaiWindowID: resolvedWindowID, status: status, createdAt: now, updatedAt: now)
        try validateWorkspaceFocusNames(
            workspaceID: workspaceID, processes: try store.workspaceProcesses(workspaceID: workspaceID),
            browserSessions: try store.workspaceBrowserSessions(workspaceID: workspaceID), agentWindows: existingAgentWindows + [record])
        try store.upsertAgentWindow(record)
        return record
    }

    @discardableResult public func updateAgentWindowStatus(
        workspaceID: String, provider: AgentProvider, terminalTrackingID: String? = nil, codexThreadID: String? = nil, tmuxWindowID: String? = nil,
        terminalNativeID: String? = nil, yabaiWindowID: Int? = nil, label: String? = nil, status: AgentWindowStatus,
        claimedLauncherName: String? = nil
    ) throws -> AgentWindowRecord {
        let now = nowISO8601()
        let allAgentWindows = try store.agentWindows(workspaceID: workspaceID)
        let matchedProcess = try matchedWorkspaceProcessForAgent(
            workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID, yabaiWindowID: yabaiWindowID,
            tmuxWindowID: tmuxWindowID)
        let resolvedTmuxWindowID = tmuxWindowID ?? matchedProcess?.tmuxWindowID
        let resolvedTerminalNativeID = matchedProcess?.terminalNativeID ?? terminalNativeID
        let trackedWindow = try ensureTrackedWindowExistsForAgent(
            workspaceID: workspaceID, provider: provider, label: label, terminalTrackingID: terminalTrackingID,
            terminalNativeID: resolvedTerminalNativeID, yabaiWindowID: yabaiWindowID, tmuxWindowID: resolvedTmuxWindowID)
        let resolvedWindowID = trackedWindow?.windowID ?? yabaiWindowID
        let finalTerminalNativeID = trackedWindow?.terminalNativeID ?? resolvedTerminalNativeID
        let existing = try matchingAgentWindow(
            workspaceID: workspaceID, tmuxWindowID: resolvedTmuxWindowID, terminalTrackingID: terminalTrackingID, codexThreadID: codexThreadID,
            yabaiWindowID: resolvedWindowID)
        if let existing {
            let resolvedLabel = try uniqueAgentFocusLabel(
                workspaceID: workspaceID, preferredLabel: label ?? existing.label, excludingAgentWindowID: existing.id,
                claimedLauncherName: claimedLauncherName ?? existing.label)
            let updated = AgentWindowRecord(
                id: existing.id, workspaceID: existing.workspaceID, provider: existing.provider, label: resolvedLabel,
                terminalTrackingID: terminalTrackingID ?? existing.terminalTrackingID,
                terminalNativeID: finalTerminalNativeID ?? existing.terminalNativeID, tmuxWindowID: resolvedTmuxWindowID ?? existing.tmuxWindowID,
                codexThreadID: codexThreadID ?? existing.codexThreadID, windowID: resolvedWindowID ?? existing.windowID,
                yabaiWindowID: resolvedWindowID ?? existing.yabaiWindowID, status: status, createdAt: existing.createdAt, updatedAt: now)
            try validateWorkspaceFocusNames(
                workspaceID: workspaceID, processes: try store.workspaceProcesses(workspaceID: workspaceID),
                browserSessions: try store.workspaceBrowserSessions(workspaceID: workspaceID),
                agentWindows: allAgentWindows.map { $0.id == existing.id ? updated : $0 })
            try store.upsertAgentWindow(updated)
            return updated
        }
        return try registerAgentWindow(
            workspaceID: workspaceID, provider: provider, label: label, terminalTrackingID: terminalTrackingID, tmuxWindowID: resolvedTmuxWindowID,
            terminalNativeID: resolvedTerminalNativeID, codexThreadID: codexThreadID, yabaiWindowID: yabaiWindowID, status: status,
            claimedLauncherName: claimedLauncherName)
    }

    @discardableResult public func handleAgentExit(
        workspaceID: String, provider: AgentProvider, terminalTrackingID: String? = nil, tmuxWindowID: String? = nil, codexThreadID: String? = nil,
        terminalNativeID: String? = nil, yabaiWindowID: Int? = nil, label: String? = nil
    ) throws -> AgentWindowRecord? {
        guard
            let existing = try matchingAgentWindow(
                workspaceID: workspaceID, tmuxWindowID: tmuxWindowID, terminalTrackingID: terminalTrackingID, codexThreadID: codexThreadID,
                yabaiWindowID: yabaiWindowID)
        else { return nil }
        let resolvedWindowID =
            try matchedTrackedWindowForAgent(
                workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID ?? existing.terminalTrackingID,
                yabaiWindowID: yabaiWindowID ?? existing.yabaiWindowID ?? existing.windowID, tmuxWindowID: existing.tmuxWindowID)?.windowID
            ?? yabaiWindowID ?? existing.yabaiWindowID ?? existing.windowID
        if agentWindowIsOpen(resolvedWindowID) || existing.tmuxWindowID != nil {
            return try updateAgentWindowStatus(
                workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID ?? existing.terminalTrackingID,
                codexThreadID: codexThreadID ?? existing.codexThreadID, tmuxWindowID: tmuxWindowID ?? existing.tmuxWindowID,
                terminalNativeID: terminalNativeID ?? existing.terminalNativeID, yabaiWindowID: resolvedWindowID, label: label ?? existing.label,
                status: .idle)
        }
        try store.deleteAgentWindow(id: existing.id)
        try removeAdHocTrackedWindowForAgent(
            workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID ?? existing.terminalTrackingID,
            yabaiWindowID: resolvedWindowID, tmuxWindowID: existing.tmuxWindowID)
        return nil
    }

    public func focusAgentWindow(_ record: AgentWindowRecord) throws {
        let focused = try focusAgentWindowRecord(record)
        guard focused else { throw missingTrackedAgentError(record) }
        rememberNavigationTarget(.agent(record), workspaceID: record.workspaceID)
        try markWorkspaceRunningIfNeeded(workspaceID: record.workspaceID)
        try setActiveWorkspace(id: record.workspaceID)
    }

    public func restartWorkspaceProcess(workspaceID: String, processID: String) throws {
        guard let process = try store.runningProcesses(workspaceID: workspaceID).first(where: { $0.id == processID }) else { return }
        try restartProcessInTerminal(workspaceID: workspaceID, process: process)
    }

    public func stopWorkspaceProcess(workspaceID: String, processID: String) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            guard let process = try store.runningProcesses(workspaceID: workspaceID).first(where: { $0.id == processID }) else { return }
            try stopRunningProcess(process, workspaceID: workspaceID)
        }
    }

    public func recoverMissingConfiguredProcess(workspaceID: String, processKey: String) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        guard let template = (settings?.processes ?? []).first(where: { configuredProcessMatchesKey($0, key: processKey) }) else {
            throw MuxyError.invalidArgument(message: "Configured process not found for recovery.")
        }
        let running = try store.runningProcesses(workspaceID: workspaceID)
        let expectedKey = configuredProcessMatchKey(name: template.name)
        guard !running.contains(where: { runningProcessMatchKey(name: $0.templateName) == expectedKey }) else {
            try markWorkspaceRunningIfNeeded(workspace)
            return
        }

        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        let terminalHost = try configuredTerminalHost()
        guard terminalAdapterAvailable(terminalHost) else {
            throw MuxyError.dependencyMissing(message: missingTerminalDependencyMessage(for: terminalHost, operation: "launch processes"))
        }
        guard tmux.isAvailable() else { throw MuxyError.dependencyMissing(message: "tmux is required to launch processes.") }
        _ = try launchConfiguredProcess(template: template, workspace: workspace, env: env, terminalHost: terminalHost)
        try markWorkspaceRunningIfNeeded(workspace)
    }

    @discardableResult public func launchAgentLauncher(workspaceID: String, name: String, background: Bool = false) throws -> AgentWindowRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw MuxyError.invalidArgument(message: "Coding agent name is required.") }
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        guard let launcher = settings?.agentLaunchers.first(where: { normalizedFocusName($0.name) == normalizedFocusName(trimmedName) }) else {
            throw MuxyError.invalidArgument(message: "Configured coding agent not found.")
        }

        if let existing = try store.agentWindows(workspaceID: workspaceID).first(where: {
            normalizedFocusName($0.label ?? "") == normalizedFocusName(launcher.name)
        }) {
            if try focusAgentWindowRecord(existing) {
                try markWorkspaceRunningIfNeeded(workspace)
                return existing
            }
            let existingWindowID = try trackedAgentWindowID(existing) ?? existing.yabaiWindowID ?? existing.windowID
            // A failed focus attempt is not enough evidence to destroy the reserved row.
            // Only evict the existing record when its terminal is actually gone; otherwise
            // keep the current slot and treat launch as an idempotent no-op.
            if agentWindowIsOpen(existingWindowID) || existing.tmuxWindowID != nil {
                try markWorkspaceRunningIfNeeded(workspace)
                return existing
            }
            try removeStaleAgentWindow(existing)
        }

        let terminalHost = try configuredTerminalHost()
        guard terminalAdapterAvailable(terminalHost) else {
            throw MuxyError.dependencyMissing(message: missingTerminalDependencyMessage(for: terminalHost, operation: "launch coding agents"))
        }

        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        let launchEnv = terminalLaunchEnvironment(
            base: env.merging([Self.agentLabelEnvVar: launcher.name]) { _, new in new }, terminalHost: terminalHost)
        let snapshot = bestEffortYabaiWindowSnapshot()
        let terminalHandle = try openManagedTerminalWindow(
            terminalHost: terminalHost, command: wrappedAgentLauncherCommand(name: launcher.name, command: applyEnvVars(launcher.command, env: env)),
            cwd: workspace.dir, environment: launchEnv, background: background)
        let capturedWindowID =
            bestEffortCaptureNewAppWindowID(snapshot: snapshot, appName: terminalAppName(for: terminalHost)) ?? terminalHandle.fallbackWindowID
        let record = try registerAgentWindow(
            workspaceID: workspace.id, provider: agentProvider(for: terminalHost), label: launcher.name,
            terminalTrackingID: storedTerminalHookSessionID(terminalHost: terminalHost, handle: terminalHandle),
            terminalNativeID: storedTerminalNativeID(terminalHost: terminalHost, handle: terminalHandle), yabaiWindowID: capturedWindowID,
            status: .idle, claimedLauncherName: launcher.name)
        try markWorkspaceRunningIfNeeded(workspace)
        return record
    }

    private func configuredProcessMatchesKey(_ template: ProcessTemplate, key: String) -> Bool {
        let trimmedName = template.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmedName.isEmpty && trimmedName == key
    }

    private func wrappedAgentLauncherCommand(name: String, command: String) -> String {
        let escapedName = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "'\\''")
        return "printf '\\033]0;\(escapedName)\\007'; \(command)"
    }

    public func recoverRunningWorkspaceProcessIfPossible(workspaceID: String, processID: String) throws -> Bool {
        guard let process = try store.runningProcesses(workspaceID: workspaceID).first(where: { $0.id == processID }) else { return false }
        return try recoverRunningProcessTerminalIfPossible(workspaceID: workspaceID, process: process)
    }

    public func recoverMissingBrowserSession(workspaceID: String, targetURL: String) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let sessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        guard !sessions.isEmpty else { throw MuxyError.invalidArgument(message: "No browser sessions are configured for this workspace.") }
        guard chrome.isAvailable() else { throw MuxyError.dependencyMissing(message: "Google Chrome is required for browser sessions.") }

        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        let resolvedSessions = resolveBrowserSessions(sessions, env: env)
        guard let matchedSession = resolvedSessions.filter({ targetURL.hasPrefix($0.prefix) }).max(by: { $0.prefix.count < $1.prefix.count }) else {
            throw MuxyError.invalidArgument(message: "Browser session not found for recovery.")
        }

        let snapshot = bestEffortYabaiWindowSnapshot()
        _ = try chrome.openWindow(url: matchedSession.prefix, background: false)
        guard let newWindow = try captureNewAppWindow(snapshot: snapshot, appName: "Google Chrome") else {
            throw MuxyError.invalidArgument(message: "Failed to recover browser session window.")
        }

        var updatedSessions = sessions
        updatedSessions[matchedSession.index].extractedWindow = ExtractedBrowserWindowMapping(
            targetURL: matchedSession.prefix, windowID: newWindow.id, isValid: true)
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: updatedSessions)

        let trackedWindows = try store.windows(workspaceID: workspace.id)
        let existingWindow = trackedWindows.first(where: { window in
            guard window.role == "browser", let trackedTargetURL = window.targetURL else { return false }
            return trackedTargetURL == matchedSession.prefix || matchedSession.prefix.hasPrefix(trackedTargetURL)
        })
        let storedWindow = WindowRecord(
            id: existingWindow?.id ?? UUID().uuidString, workspaceID: workspace.id, app: newWindow.app,
            name: try browserFocusName(workspaceID: workspace.id, targetURL: matchedSession.prefix) ?? matchedSession.prefix,
            detail: matchedSession.prefix, targetURL: matchedSession.prefix, windowID: newWindow.id, role: "browser",
            orderIndex: existingWindow?.orderIndex ?? matchedSession.index, lastSeenAt: nowISO8601())
        try store.upsert(window: storedWindow)
        try markWorkspaceRunningIfNeeded(workspace)
    }

    private func markWorkspaceRunningIfNeeded(_ workspace: WorkspaceRecord) throws {
        guard !workspace.isRunning else { return }
        let launchedAt = workspace.lastLaunchedAt ?? nowISO8601()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: launchedAt)
    }

    private func markWorkspaceRunningIfNeeded(workspaceID: String) throws {
        guard let workspace = try store.workspace(id: workspaceID) else { return }
        try markWorkspaceRunningIfNeeded(workspace)
    }

    private func stopRunningProcess(_ process: RunningProcessRecord, workspaceID: String) throws {
        if let pid = resolvedRuntimePID(for: process) { terminateProcessGroup(pid: pid) }
        if isManagedTerminalApp(process.terminalApp) { _ = try? closeTrackedItermTerminalContainer(process) }
        let sessionName = processTmuxSessionName(workspaceID: workspaceID, processName: process.templateName)
        if tmux.hasSession(named: sessionName) { try? tmux.killSession(named: sessionName) }

        if let terminalWindow = try store.windows(workspaceID: workspaceID).first(where: {
            ($0.windowID != nil && $0.windowID == process.windowID) || ($0.tmuxWindowID != nil && $0.tmuxWindowID == process.tmuxWindowID)
        }) {
            if terminalWindow.role == "terminal", isManagedTerminalApp(terminalWindow.app) {
                _ = try? closeTrackedItermTerminalWindow(terminalWindow)
            } else if let windowID = terminalWindow.windowID {
                _ = try? yabai.closeWindow(id: windowID)
            }
            try store.deleteWindow(id: terminalWindow.id)
        }

        try store.deleteRunningProcess(id: process.id)

        if try !hasTrackedRuntimeIndicators(workspaceID: workspaceID), let workspace = try store.workspace(id: workspaceID) {
            try store.updateWorkspaceRunning(id: workspace.id, isRunning: false, launchedAt: workspace.lastLaunchedAt)
        }
    }

    private func recoverRunningProcessTerminalIfPossible(workspaceID: String, process: RunningProcessRecord) throws -> Bool {
        guard let terminalHost = terminalHost(for: process.terminalApp) else { return false }
        guard tmux.isAvailable() else { return false }
        guard let pid = resolvedRuntimePID(for: process), isProcessAlive(pid: pid) else { return false }
        let (_, workspace) = try resolveWorkspace(id: workspaceID)
        let sessionName = processTmuxSessionName(workspaceID: workspace.id, processName: process.templateName)
        guard tmux.hasSession(named: sessionName) else { return false }

        let snapshot = bestEffortYabaiWindowSnapshot()
        let terminalHandle = try attachProcessTmuxSession(
            workspace: workspace, processName: process.templateName, commandDescription: process.command, terminalHost: terminalHost,
            background: false)
        let capturedWindowID =
            bestEffortCaptureNewAppWindowID(snapshot: snapshot, appName: terminalAppName(for: terminalHost)) ?? terminalHandle.fallbackWindowID
        let now = nowISO8601()
        let hookSessionID = storedTerminalHookSessionID(terminalHost: terminalHost, handle: terminalHandle)
        let terminalNativeID = storedTerminalNativeID(terminalHost: terminalHost, handle: terminalHandle)
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                terminalApp: process.terminalApp, windowID: capturedWindowID, terminalTrackingID: hookSessionID, terminalNativeID: terminalNativeID,
                itermTabIndex: nil, tmuxWindowID: process.tmuxWindowID, pid: pid, status: .running, logPath: process.logPath,
                lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: nil))

        let existingWindow = try store.windows(workspaceID: workspace.id).first(where: { window in
            window.role == "terminal"
                && (window.id == process.id || window.windowID == process.windowID || window.tmuxWindowID == process.tmuxWindowID)
        })
        try store.upsert(
            window: WindowRecord(
                id: existingWindow?.id ?? process.id, workspaceID: workspace.id, app: terminalAppName(for: terminalHost), name: process.templateName,
                detail: process.command, targetURL: nil, windowID: capturedWindowID, terminalTrackingID: hookSessionID,
                terminalNativeID: terminalNativeID, itermTabIndex: nil, tmuxWindowID: process.tmuxWindowID, role: "terminal",
                orderIndex: existingWindow?.orderIndex
                    ?? Self.nextWindowOrderIndex(existing: try store.windows(workspaceID: workspace.id), role: "terminal", orderOffset: 200),
                lastSeenAt: now))
        return true
    }

    @discardableResult private func launchConfiguredProcess(
        template: ProcessTemplate, workspace: WorkspaceRecord, env: [String: String], terminalHost: TerminalHost, background: Bool = false
    ) throws -> RunningProcessRecord {
        let name = processKey(for: template)
        guard let command = parseDirectProcessCommand(template.command, env: env) else {
            throw MuxyError.invalidArgument(message: invalidDirectProcessCommandMessage(template.command, env: env))
        }
        let snapshot = try yabai.listWindows()
        let terminalHandle = try launchProcessInTmux(
            workspace: workspace, processName: name, rawCommand: template.command, command: command, env: env, terminalHost: terminalHost,
            background: background, replaceExistingSession: true)
        let capturedWindowID =
            bestEffortCaptureNewAppWindowID(snapshot: snapshot, appName: terminalAppName(for: terminalHost)) ?? terminalHandle.fallbackWindowID
        let tmuxWindow = try currentTmuxWindowInfo(workspaceID: workspace.id, processName: name)
        let hookSessionID = storedTerminalHookSessionID(terminalHost: terminalHost, handle: terminalHandle)
        let terminalNativeID = storedTerminalNativeID(terminalHost: terminalHost, handle: terminalHandle)
        let record = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: name, command: template.command,
            terminalApp: terminalAppName(for: terminalHost), windowID: capturedWindowID, terminalTrackingID: hookSessionID,
            terminalNativeID: terminalNativeID, itermTabIndex: nil, tmuxWindowID: tmuxWindow?.id, pid: tmuxWindow?.panePID, status: .running,
            logPath: nil, lastOutputAt: nil, startedAt: nowISO8601(), exitedAt: nil)
        try store.upsert(runningProcess: record)
        let nextOrder = Self.nextWindowOrderIndex(existing: try store.windows(workspaceID: workspace.id), role: "terminal", orderOffset: 200)
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: terminalAppName(for: terminalHost), name: name, detail: template.command,
                targetURL: nil, windowID: capturedWindowID, terminalTrackingID: hookSessionID, terminalNativeID: terminalNativeID, itermTabIndex: nil,
                tmuxWindowID: tmuxWindow?.id, role: "terminal", orderIndex: nextOrder, lastSeenAt: nowISO8601()))
        return record
    }

    private func focusWorkspaceProcessRecord(_ process: RunningProcessRecord, workspaceID: String) throws -> Bool {
        guard isManagedTerminalApp(process.terminalApp) else { return false }
        let target = try resolvedProcessTerminalFocusTarget(process, workspaceID: workspaceID)
        guard let trackedWindowID = target.windowID else { return false }
        let adapterFocused = focusManagedTerminal(
            terminalApp: process.terminalApp, trackingIdentity: target.trackingIdentity, windowID: trackedWindowID, tabIndex: target.tabIndex)
        let focused = adapterFocused == true ? true : ((try? yabai.focusWindow(id: trackedWindowID)) ?? false)
        if focused, let tmuxWindowID = process.tmuxWindowID, !tmuxWindowID.isEmpty { _ = try? tmux.selectWindow(windowID: tmuxWindowID) }
        if focused { pulseTerminalWindowIfNeeded(windowID: trackedWindowID) }
        return focused
    }

    private func resolvedProcessTerminalFocusTarget(_ process: RunningProcessRecord, workspaceID: String) throws -> TerminalFocusTarget {
        let windows = try store.windows(workspaceID: workspaceID)
        let trackedWindow = windows.first(where: { window in
            guard window.role == "terminal", window.app == process.terminalApp else { return false }
            if window.id == process.id { return true }
            if let tmuxWindowID = process.tmuxWindowID, window.tmuxWindowID == tmuxWindowID { return true }
            if let terminalID = process.terminalNativeID, !terminalID.isEmpty, window.terminalNativeID == terminalID { return true }
            if let terminalID = process.terminalTrackingID, !terminalID.isEmpty, window.terminalTrackingID == terminalID { return true }
            if let windowID = process.windowID, window.windowID == windowID { return true }
            return false
        })
        let trackedSessionIdentity = trackedWindow?.terminalFocusIdentity
        let processSessionIdentity = process.terminalFocusIdentity
        let trackingIdentity =
            trackedSessionIdentity ?? processSessionIdentity ?? trackedWindow?.windowID.map(TerminalTrackingIdentity.window) ?? process.windowID.map(
                TerminalTrackingIdentity.window) ?? trackedWindow?.tmuxWindowID.map(TerminalTrackingIdentity.tmux)
            ?? process.tmuxWindowID.map(TerminalTrackingIdentity.tmux)
        return TerminalFocusTarget(
            trackingIdentity: trackingIdentity, windowID: trackedWindow?.windowID ?? process.windowID,
            tabIndex: trackedWindow?.itermTabIndex ?? process.itermTabIndex)
    }

    private func trackedAgentWindowID(_ record: AgentWindowRecord) throws -> Int? {
        if let tmuxWindowID = record.tmuxWindowID, !tmuxWindowID.isEmpty {
            let terminalApp = TerminalHost(rawValue: record.provider.rawValue)?.appName ?? TerminalHost.iterm2.appName
            if let windowID = try store.windows(workspaceID: record.workspaceID).first(where: {
                $0.app == terminalApp && $0.role == "terminal" && $0.tmuxWindowID == tmuxWindowID
            })?.windowID {
                return windowID
            }
        }
        let terminalApp = TerminalHost(rawValue: record.provider.rawValue)?.appName ?? TerminalHost.iterm2.appName
        if record.provider == .ghostty, let terminalID = record.terminalNativeID, !terminalID.isEmpty {
            if let windowID = try store.windows(workspaceID: record.workspaceID).first(where: {
                $0.app == terminalApp && $0.role == "terminal" && $0.terminalNativeID == terminalID
            })?.windowID {
                return windowID
            }
            // Older or partially reconciled Ghostty rows may still only carry the hook token on
            // their tracked terminal window. If native-ID lookup misses, fall back to that same
            // persisted tracking token rather than inferring from frontmost Ghostty state.
        }
        // iTerm rows, and older Ghostty rows that have not been backfilled with a native
        // terminal ID yet, still reconcile through the persisted shell/session identity.
        guard let sessionID = record.terminalTrackingID, !sessionID.isEmpty else { return record.yabaiWindowID ?? record.windowID }
        return try store.windows(workspaceID: record.workspaceID).first(where: {
            $0.app == terminalApp && $0.role == "terminal" && $0.terminalTrackingID == sessionID
        })?.windowID
    }

    private func focusAgentWindowRecord(_ record: AgentWindowRecord) throws -> Bool {
        let windowID = try trackedAgentWindowID(record) ?? record.yabaiWindowID ?? record.windowID
        let terminalApp = TerminalHost(rawValue: record.provider.rawValue)?.appName
        let adapterFocused = focusManagedTerminal(
            terminalApp: terminalApp, trackingIdentity: record.terminalFocusIdentity, windowID: windowID, tabIndex: nil)
        let focused: Bool
        if adapterFocused == true {
            focused = true
        } else if let windowID {
            focused = (try? yabai.focusWindow(id: windowID)) ?? false
        } else {
            focused = false
        }
        if focused, let tmuxWindowID = record.tmuxWindowID, !tmuxWindowID.isEmpty { _ = try? tmux.selectWindow(windowID: tmuxWindowID) }
        if focused, let windowID { pulseTerminalWindowIfNeeded(windowID: windowID) }
        return focused
    }

    private func missingTrackedWindowError(for window: WindowRecord, workspaceID: String) -> MuxyError {
        if window.role == "browser" {
            return .missingTrackedWindow(
                MissingTrackedWindowContext(
                    kind: .browserSession, workspaceID: workspaceID, windowID: window.windowID, targetURL: window.targetURL,
                    title: window.name ?? window.targetURL ?? "Browser Session"))
        }
        return .missingTrackedWindow(
            MissingTrackedWindowContext(kind: .window, workspaceID: workspaceID, windowID: window.windowID, title: window.name ?? window.app))
    }

    private func missingTrackedProcessError(_ process: RunningProcessRecord, workspaceID: String) -> MuxyError {
        .missingTrackedWindow(
            MissingTrackedWindowContext(
                kind: .process, workspaceID: workspaceID, windowID: process.windowID, processID: process.id, title: process.templateName))
    }

    private func missingTrackedAgentError(_ record: AgentWindowRecord) -> MuxyError {
        .missingTrackedWindow(
            MissingTrackedWindowContext(
                kind: .codingAgent, workspaceID: record.workspaceID, windowID: record.windowID ?? record.yabaiWindowID,
                title: record.label ?? "Coding Agent CLI"))
    }

    private func safeFilename(_ raw: String) -> String {
        raw.map { char in
            if char.isLetter || char.isNumber { return char }
            return "_"
        }.reduce("") { $0 + String($1) }
    }

}
