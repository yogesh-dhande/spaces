import CryptoKit
import Darwin
import Foundation
@preconcurrency import UserNotifications
import spacesterminalcore
import systembridge

public final class WorkspaceOrchestrator {
    public typealias BuiltInTerminalWindowOpener = @Sendable (String, TerminalAttachmentMode) -> Void
    public typealias BuiltInTerminalWindowFocuser = @Sendable (String, String?) -> Void
    public typealias BuiltInTerminalWindowCloser = @Sendable (String) -> Void
    public typealias BuiltInTerminalSessionTerminator = @Sendable (String) -> Void
    public typealias BuiltInTerminalSessionLauncher = @Sendable (TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary

    private final class NotificationAuthorizationCache: @unchecked Sendable {
        private let lock = NSLock()
        private var status: UNAuthorizationStatus?

        func set(_ status: UNAuthorizationStatus) {
            lock.lock()
            self.status = status
            lock.unlock()
        }

        func get() -> UNAuthorizationStatus? {
            lock.lock()
            defer { lock.unlock() }
            return status
        }
    }

    private final class BuiltInTerminalSessionLauncherOverrideStore: @unchecked Sendable {
        private let lock = NSLock()
        private var launcher: BuiltInTerminalSessionLauncher?

        func set(_ launcher: BuiltInTerminalSessionLauncher?) {
            lock.lock()
            self.launcher = launcher
            lock.unlock()
        }

        func get() -> BuiltInTerminalSessionLauncher? {
            lock.lock()
            defer { lock.unlock() }
            return launcher
        }
    }

    private final class BuiltInTerminalSessionTerminatorOverrideStore: @unchecked Sendable {
        private let lock = NSLock()
        private var terminator: BuiltInTerminalSessionTerminator?

        func set(_ terminator: BuiltInTerminalSessionTerminator?) {
            lock.lock()
            self.terminator = terminator
            lock.unlock()
        }

        func get() -> BuiltInTerminalSessionTerminator? {
            lock.lock()
            defer { lock.unlock() }
            return terminator
        }
    }

    public static let terminalTrackingIDEnvVar = "SPACES_TERMINAL_TRACKING_ID"
    public static let agentLabelEnvVar = "SPACES_AGENT_LABEL"
    private static let notificationAuthorizationCache = NotificationAuthorizationCache()
    private static let builtInTerminalSessionLauncherOverrideStore = BuiltInTerminalSessionLauncherOverrideStore()
    private static let builtInTerminalSessionTerminatorOverrideStore = BuiltInTerminalSessionTerminatorOverrideStore()

    public struct WorkspaceStopOutcome: Sendable {
        public let skippedStopScriptBecauseWorkspaceDirectoryMissing: Bool

        public init(skippedStopScriptBecauseWorkspaceDirectoryMissing: Bool) {
            self.skippedStopScriptBecauseWorkspaceDirectoryMissing = skippedStopScriptBecauseWorkspaceDirectoryMissing
        }
    }

    public struct WorkspaceArchiveOutcome: Sendable {
        public let notice: String?

        public init(notice: String?) { self.notice = notice }
    }

    public struct PreparedGitProjectImport: Sendable {
        public let project: ProjectRecord
        public let defaultWorkspace: WorkspaceRecord
        public let importedDocument: SpacesYAMLDocument?

        public init(project: ProjectRecord, defaultWorkspace: WorkspaceRecord, importedDocument: SpacesYAMLDocument?) {
            self.project = project
            self.defaultWorkspace = defaultWorkspace
            self.importedDocument = importedDocument
        }
    }

    public struct ManagedDirectoryReplacementCandidate: Equatable, Sendable {
        public enum Kind: String, Hashable, Sendable {
            case projectRepository
            case workspaceDirectory
        }

        public let kind: Kind
        public let path: String

        public init(kind: Kind, path: String) {
            self.kind = kind
            self.path = path
        }
    }

    public static func setProcessWideBuiltInTerminalSessionLauncher(_ launcher: BuiltInTerminalSessionLauncher?) {
        builtInTerminalSessionLauncherOverrideStore.set(launcher)
    }

    public static func setProcessWideBuiltInTerminalSessionTerminator(_ terminator: BuiltInTerminalSessionTerminator?) {
        builtInTerminalSessionTerminatorOverrideStore.set(terminator)
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

    private struct WorkspaceConfigurationSnapshot {
        let workspace: WorkspaceRecord
        let settings: WorkspaceSettings?
        let assignedPorts: [(definitionID: String, port: Int, name: String)]
    }

    private struct GitProjectImportPlan {
        let gitURL: String
        let project: ProjectRecord
        let destination: URL
    }

    private struct BrowserWindowScanResult {
        let windows: [WindowRecord]
        let tabIndexByWindowAndURL: [String: Int]
    }

    private struct CachedScannedBrowserTabTarget {
        let tabIndex: Int
        let browserPrefixes: [String]
    }

    private struct ScannedBrowserFocusTarget {
        let windowID: Int
        let tabIndex: Int
        let matchedURL: String
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
        let providerIdentity: TerminalTrackingIdentity?
        let hookAttributionID: String?
        let containerIdentity: String?
    }

    private struct SpacesTerminalSessionHandle {
        let sessionID: String
        let childPID: Int?
        let windowID: Int?
        let outputPath: String
    }

    private struct WorkspaceSetupRunResult {
        let exitCode: Int
        let logPath: String
    }

    private struct BuiltInTerminalSessionOwnership {
        let process: RunningProcessRecord?
        let agent: AgentWindowRecord?
        let terminalWindowWorkspaceID: String?
        let launchWorkspaceID: String?
        let launchKind: TerminalSessionKind?

        var processWorkspaceID: String? { process?.workspaceID }
        var agentWorkspaceID: String? { agent?.workspaceID }
    }

    public struct WorkspaceTerminalLaunchReservation: Sendable {
        public let sessionID: String
        let workspaceID: String
        let windowRecordID: String
        let appName: String
        let title: String
        let launchConfiguration: TerminalSessionLaunchConfiguration
        let createdAt: String
        let orderIndex: Int
    }

    private enum ManagedTerminalFocusResult {
        case existingWindow
        case trackedTerminal
        case sessionRequest
        case reboundSession(windowID: Int?)
        case reopenedSession(windowID: Int?)
        case unavailable
    }

    private struct WorkspaceProcessFocusOutcome {
        let focused: Bool
        let route: String
        let focusedExistingWindow: Bool
    }

    private enum WorkspaceNavigationCursor: Hashable {
        case agent(String)
        case process(String)
        case terminal(String)
        case browserWindowURL(Int, String)
        case browserURL(String)
        case window(Int)
    }

    private struct WorkspaceNavigationCycleSession {
        let orderedCursors: [WorkspaceNavigationCursor]
        var currentIndex: Int
        var lastUsedAt: Date
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
    private let notificationDeliverer: (String, String, String?) -> Void
    private let builtInTerminalWindowOpener: BuiltInTerminalWindowOpener
    private let builtInTerminalWindowFocuser: BuiltInTerminalWindowFocuser
    private let builtInTerminalWindowCloser: BuiltInTerminalWindowCloser
    private let builtInTerminalSessionTerminator: BuiltInTerminalSessionTerminator
    private let builtInTerminalSessionLauncher: BuiltInTerminalSessionLauncher
    private let projectsRootDirectoryURL: URL?
    private let workspacesRootDirectoryURL: URL?
    private let terminalAdaptersByHost: [TerminalHost: any TerminalAdapter]
    private let workspaceLifecycleLock = NSLock()
    private var workspaceLifecycleInFlight: Set<String> = []
    private let workspaceSetupLock = NSLock()
    private var workspaceSetupInFlight: Set<String> = []
    private let windowNavigationLock = NSLock()
    private var windowNavigationCursorByWorkspace: [String: WorkspaceNavigationCursor] = [:]
    private var windowNavigationHistoryByWorkspace: [String: [WorkspaceNavigationCursor]] = [:]
    private var windowNavigationCycleSessionByWorkspace: [String: WorkspaceNavigationCycleSession] = [:]
    private let browserScanCacheLock = NSLock()
    private var browserWindowScanCacheByWorkspace: [String: BrowserWindowScanCacheEntry] = [:]
    private let itermTerminalSessionLock = NSLock()
    private var itermTerminalSessionByWorkspaceAndWindowID: [String: ItermTerminalSessionMetadata] = [:]
    private let terminalFocusPulseController: TerminalFocusPulseControlling
    private let windowNavigationCycleSessionTimeout: TimeInterval = 2
    private let windowNavigationHistoryLimit = 64
    private let processStartupVerificationTimeout: TimeInterval = 1

    public init(
        store: SQLiteStore, projectsRootDirectory: URL? = nil, workspacesRootDirectory: URL? = nil, git: GitClient = .init(),
        yabai: YabaiAdapter = .init(), iterm: Iterm2Adapter = .init(), ghostty: GhosttyAdapter = .init(), tmux: TmuxAdapter = .init(),
        chrome: ChromeAdapter = .init(), browserWindowScanDebounceInterval: TimeInterval = PollingConstants.browserWindowScanDebounceInterval,
        terminalFocusPulseController: TerminalFocusPulseControlling = TerminalFocusPulseController(),
        notificationDeliverer: ((String, String, String?) -> Void)? = nil, builtInTerminalWindowOpener: BuiltInTerminalWindowOpener? = nil,
        builtInTerminalWindowFocuser: BuiltInTerminalWindowFocuser? = nil, builtInTerminalWindowCloser: BuiltInTerminalWindowCloser? = nil,
        builtInTerminalSessionTerminator: BuiltInTerminalSessionTerminator? = nil,
        builtInTerminalSessionLauncher: BuiltInTerminalSessionLauncher? = nil, currentDate: @escaping () -> Date = Date.init
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
        terminalAdaptersByHost = [:]
        self.browserWindowScanDebounceInterval = browserWindowScanDebounceInterval
        self.terminalFocusPulseController = terminalFocusPulseController
        self.notificationDeliverer = notificationDeliverer ?? Self.deliverUserNotification
        self.builtInTerminalWindowOpener =
            builtInTerminalWindowOpener ?? { sessionID, mode in
                guard let object = try? IPCNotification.currentObject() else { return }
                DistributedNotificationCenter.default().postNotificationName(
                    IPCNotification.openTerminalSessionWindow, object: object,
                    userInfo: [
                        IPCNotification.terminalSessionIDUserInfoKey: sessionID, IPCNotification.terminalAttachmentModeUserInfoKey: mode.rawValue,
                    ], options: [.deliverImmediately])
            }
        self.builtInTerminalWindowFocuser =
            builtInTerminalWindowFocuser ?? { sessionID, requestID in
                var userInfo: [String: String] = [
                    IPCNotification.terminalSessionIDUserInfoKey: sessionID,
                    IPCNotification.terminalAttachmentModeUserInfoKey: TerminalAttachmentMode.owner.rawValue,
                ]
                if let requestID, !requestID.isEmpty { userInfo[IPCNotification.focusRequestIDUserInfoKey] = requestID }
                guard let object = try? IPCNotification.currentObject() else { return }
                DistributedNotificationCenter.default().postNotificationName(
                    IPCNotification.openTerminalSessionWindow, object: object, userInfo: userInfo, options: [.deliverImmediately])
            }
        self.builtInTerminalWindowCloser =
            builtInTerminalWindowCloser ?? { sessionID in
                guard let object = try? IPCNotification.currentObject() else { return }
                DistributedNotificationCenter.default().postNotificationName(
                    IPCNotification.closeTerminalSessionWindow, object: object,
                    userInfo: [
                        IPCNotification.terminalSessionIDUserInfoKey: sessionID, IPCNotification.terminalSessionIsTerminatingUserInfoKey: "true",
                    ], options: [.deliverImmediately])
            }
        self.builtInTerminalSessionTerminator =
            builtInTerminalSessionTerminator ?? Self.builtInTerminalSessionTerminatorOverrideStore.get() ?? { sessionID in
                try? TerminalService.terminateSession(id: sessionID)
            }
        self.builtInTerminalSessionLauncher =
            builtInTerminalSessionLauncher ?? Self.builtInTerminalSessionLauncherOverrideStore.get() ?? { launchConfiguration in
                try TerminalService.createSession(launchConfiguration)
            }
        self.currentDate = currentDate
        if ProcessInfo.processInfo.environment["DEBUG"] == "1" { fputs("spaces: DEBUG=1 enabled (browser/cycle profiling active)\n", stderr) }
    }

    @discardableResult public func syncConfig() throws -> AppConfig { try store.appConfig() }

    public func appConfig() throws -> AppConfig { try store.appConfig() }

    @discardableResult public func updatePortRange(_ range: PortRange) throws -> AppConfig {
        var config = try store.appConfig()
        config.portRange = range
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

    public func project(dir: String) throws -> ProjectRecord? { try store.project(dir: dir) }

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
                isArchived: $0.isArchived, isHidden: $0.isHidden, isDefault: $0.isDefault, notes: $0.notes)
        }
    }

    public func suggestedWorkspaceName(projectID: String) throws -> String {
        guard let project = try store.project(id: projectID) else { throw WorkspaceError.missingProject(dir: projectID) }
        let existingNames = Set(try store.workspaces(projectID: project.id, includeArchived: true).map(\.title))
        if let suggestion = WorkspaceOrchestrator.suggestWorkspaceName(existingNames: existingNames) { return suggestion }
        throw WorkspaceError.invalidArgument(message: "No available workspace names remain for project \(project.name).")
    }

    public static func suggestWorkspaceName(existingNames: Set<String>) -> String? {
        workspaceFoodNames.first(where: { !existingNames.contains($0) })
    }

    public func gitBranchOptions(projectID: String, includeLiveRemoteHeads: Bool = true) throws -> [String] {
        guard let project = try store.project(id: projectID) else { throw WorkspaceError.missingProject(dir: projectID) }
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
            throw WorkspaceError.missingProject(dir: project.dir)
        }
        let previousPorts = existing.ports
        let previousProcesses = existing.processes
        let previousAgentLaunchers = existing.agentLaunchers
        update(&existing)
        existing.ports = normalizePortDefinitionIDs(previous: previousPorts, updated: existing.ports)
        existing.ports = try normalizedPortDefinitions(existing.ports)
        existing.processes = normalizeProcessTemplateIDs(previous: previousProcesses, updated: existing.processes)
        existing.agentLaunchers = normalizeAgentLauncherIDs(previous: previousAgentLaunchers, updated: existing.agentLaunchers)
        try validateProcessTemplates(existing.processes)
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
            throw WorkspaceError.missingProject(dir: project.dir)
        }
        let normalizedProcesses = normalizeProcessTemplateIDs(previous: existing.processes, updated: processes)
        try validateProcessTemplates(normalizedProcesses)
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

    public func updateWorkspaceNotes(workspaceID: String, notes: String?) throws {
        let (_, workspace) = try resolveWorkspace(id: workspaceID)
        try store.updateWorkspaceNotes(id: workspace.id, notes: notes)
    }

    public func updateWorkspaceHidden(workspaceID: String, isHidden: Bool) throws {
        let (_, workspace) = try resolveWorkspace(id: workspaceID)
        guard workspace.isHidden != isHidden else { return }
        try store.updateWorkspaceHidden(id: workspace.id, isHidden: isHidden)
    }

    public func updateWorkspaceName(workspaceID: String, name: String) throws {
        let (_, workspace) = try resolveWorkspace(id: workspaceID)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw WorkspaceError.invalidArgument(message: "Workspace name is required.") }
        if trimmedName == workspace.title { return }
        try store.updateWorkspaceName(id: workspace.id, name: trimmedName)
    }

    public func updateWorkspaceMetadata(
        workspaceID: String, title: String? = nil, branch: String? = nil, directoryName: String? = nil, notes: String?? = nil
    ) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        var updatedTitle = workspace.title
        var updatedBranch = workspace.branch
        var updatedDirname = workspace.dirname
        var updatedNotes = workspace.notes
        var didChange = false

        if let title {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { throw WorkspaceError.invalidArgument(message: "Workspace title is required.") }
            if trimmedTitle != workspace.title {
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
            guard project.isGitRepo else { throw WorkspaceError.invalidArgument(message: "Branch can only be updated for git projects.") }
            let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBranch.isEmpty else { throw WorkspaceError.invalidArgument(message: "Workspace branch is required.") }
            if let currentBranch = workspace.branch, isProtectedBranchName(currentBranch), trimmedBranch != currentBranch {
                throw WorkspaceError.invalidArgument(message: "Protected branches main/master cannot be renamed.")
            }
            if trimmedBranch != workspace.branch {
                if let existing = try workspaceForBranch(projectID: workspace.projectID, branch: trimmedBranch), existing.id != workspace.id {
                    throw WorkspaceError.invalidArgument(message: "Branch '\(trimmedBranch)' is already used by workspace '\(existing.title)'.")
                }
                try git.renameCurrentBranch(path: workspace.dir, to: trimmedBranch)
                updatedBranch = trimmedBranch
                didChange = true
            }
        }

        if let directoryName {
            guard project.isGitRepo else { throw WorkspaceError.invalidArgument(message: "Directory name can only be updated for git projects.") }
            let trimmedDirectoryName = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDirectoryName.isEmpty else { throw WorkspaceError.invalidArgument(message: "Workspace directory name cannot be empty.") }
            try validateWorkspaceDirname(trimmedDirectoryName)
            let usedDirnames = try usedWorkspaceDirnames(project: project, excludingDirname: workspace.dirname)
            guard !usedDirnames.contains(trimmedDirectoryName) else {
                throw WorkspaceError.invalidArgument(message: "Workspace directory name is already in use: \(trimmedDirectoryName)")
            }
            if trimmedDirectoryName != workspace.dirname {
                updatedDirname = trimmedDirectoryName
                didChange = true
            }
        }

        if let notes {
            if notes != workspace.notes {
                updatedNotes = notes
                didChange = true
            }
        }

        guard didChange else { return }
        if workspace.isDefault {
            if updatedBranch != workspace.branch { try store.updateWorkspaceBranch(id: workspace.id, branch: updatedBranch) }
            if updatedDirname != workspace.dirname { try store.updateWorkspaceDirname(id: workspace.id, dirname: updatedDirname) }
            if updatedNotes != workspace.notes { try store.updateWorkspaceNotes(id: workspace.id, notes: updatedNotes) }
            return
        }
        let updatedWorkspace = WorkspaceRecord(
            id: workspace.id, projectID: workspace.projectID, title: updatedTitle, dir: workspace.dir, dirname: updatedDirname, branch: updatedBranch,
            targetBranch: workspace.targetBranch, isDefault: workspace.isDefault, isArchived: workspace.isArchived, isHidden: workspace.isHidden,
            isRunning: workspace.isRunning, lastLaunchedAt: workspace.lastLaunchedAt, notes: updatedNotes)
        try store.upsert(workspace: updatedWorkspace)
    }

    public func addProject(dir: String) throws -> ProjectRecord { try addProject(dir: dir) { _ in } }

    public func previewProject(dir: String) throws -> ProjectRecord {
        let normalizedDir = normalizePath(dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedDir, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceError.invalidArgument(message: "Project directory not found: \(normalizedDir)")
        }
        if try store.project(dir: normalizedDir) != nil { throw WorkspaceError.projectAlreadyExists(dir: normalizedDir) }
        let importedDocument = try spacesYAMLDocumentIfPresent(in: URL(fileURLWithPath: normalizedDir, isDirectory: true))
        return try configuredProjectRecord(baseRecord: normalizeDir(id: projectID(namespace: "dir", source: normalizedDir), normalizedDir)) {
            project in importedDocument?.applying(to: &project)
        }
    }

    public func addProject(dir: String, configure: (inout ProjectRecord) -> Void) throws -> ProjectRecord {
        let normalizedDir = normalizePath(dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedDir, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceError.invalidArgument(message: "Project directory not found: \(normalizedDir)")
        }
        if try store.project(dir: normalizedDir) != nil { throw WorkspaceError.projectAlreadyExists(dir: normalizedDir) }
        let importedDocument = try spacesYAMLDocumentIfPresent(in: URL(fileURLWithPath: normalizedDir, isDirectory: true))
        let record = try configuredProjectRecord(baseRecord: normalizeDir(id: projectID(namespace: "dir", source: normalizedDir), normalizedDir)) {
            project in
            guard let importedDocument else {
                configure(&project)
                return
            }
            importedDocument.applying(to: &project)
        }
        try store.upsert(project: record)
        do { try ensureDefaultWorkspace(for: record) } catch {
            try? store.deleteProject(id: record.id)
            throw error
        }
        return record
    }

    public func addReviewedProject(dir: String, configure: (inout ProjectRecord) -> Void) throws -> ProjectRecord {
        let normalizedDir = normalizePath(dir)
        if try store.project(dir: normalizedDir) != nil { throw WorkspaceError.projectAlreadyExists(dir: normalizedDir) }
        let baseRecord = try normalizeDir(id: projectID(namespace: "dir", source: normalizedDir), normalizedDir)
        let record = try configuredProjectRecord(baseRecord: baseRecord, update: configure)
        try store.upsert(project: record)
        do { try ensureDefaultWorkspace(for: record) } catch {
            try? store.deleteProject(id: record.id)
            throw error
        }
        return record
    }

    public func addProject(gitURL: String) throws -> ProjectRecord { try addProject(gitURL: gitURL) { _ in } }

    public func addProject(gitURL: String, configure: (inout ProjectRecord) -> Void) throws -> ProjectRecord {
        let prepared = try prepareGitProject(gitURL: gitURL, replaceExistingManagedDirectories: true)
        do {
            return try addPreparedGitProject(prepared) { project in
                guard prepared.importedDocument == nil else { return }
                configure(&project)
            }
        } catch {
            try? discardPreparedGitProject(prepared)
            throw error
        }
    }

    public func prepareGitProject(gitURL: String, replaceExistingManagedDirectories: Bool = true) throws -> PreparedGitProjectImport {
        let plan = try gitProjectImportPlan(gitURL: gitURL)
        try replaceManagedGitProjectImportDirectoriesIfNeeded(plan: plan, allowReplacement: replaceExistingManagedDirectories)
        try FileManager.default.createDirectory(at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git.clone(url: plan.gitURL, destination: plan.destination.path, bare: true)

        var shouldCleanupDestination = true
        do {
            let defaultBranch = try preferredImportedDefaultBranch(path: plan.destination.path)
            let baseRecord = ProjectRecord(
                id: plan.project.id, name: plan.project.name, dir: plan.project.dir, isGitRepo: true, defaultBranch: defaultBranch)
            var record = try configuredProjectRecord(baseRecord: baseRecord) { _ in }
            let defaultWorkspace = try createImportedGitDefaultWorkspaceOnDisk(project: record, branch: defaultBranch)
            let worktreeURL = URL(fileURLWithPath: defaultWorkspace.dir, isDirectory: true)
            let importedDocument = try spacesYAMLDocumentIfPresent(in: worktreeURL)
            if let importedDocument {
                record = try configuredProjectRecord(baseRecord: record) { project in importedDocument.applying(to: &project) }
            }
            shouldCleanupDestination = false
            return PreparedGitProjectImport(project: record, defaultWorkspace: defaultWorkspace, importedDocument: importedDocument)
        } catch {
            if shouldCleanupDestination {
                try? removeManagedGitWorkspaceDirectoriesIfNeeded(project: plan.project)
                try? FileManager.default.removeItem(at: plan.destination)
            }
            throw error
        }
    }

    public func managedGitProjectImportReplacementCandidates(gitURL: String) throws -> [ManagedDirectoryReplacementCandidate] {
        try managedGitProjectImportReplacementCandidates(plan: gitProjectImportPlan(gitURL: gitURL))
    }

    public func managedWorkspaceReplacementCandidate(projectID: String, directoryName: String) throws -> ManagedDirectoryReplacementCandidate? {
        guard let project = try store.project(id: projectID) else { throw WorkspaceError.missingProject(dir: projectID) }
        guard project.isGitRepo else { return nil }
        let trimmedDirectoryName = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDirectoryName.isEmpty else { return nil }
        try validateWorkspaceDirname(trimmedDirectoryName)
        let workspaceDirectory = try worktreeRoot(project: project).appendingPathComponent(trimmedDirectoryName, isDirectory: true).path
        return try managedDirectoryReplacementCandidate(path: workspaceDirectory, kind: .workspaceDirectory)
    }

    @discardableResult public func addPreparedGitProject(_ prepared: PreparedGitProjectImport, configure: (inout ProjectRecord) -> Void) throws
        -> ProjectRecord
    {
        guard prepared.project.isGitRepo else { throw WorkspaceError.invalidArgument(message: "Prepared project must be a git project.") }
        let normalizedDir = normalizePath(prepared.project.dir)
        guard normalizedDir == prepared.project.dir else {
            throw WorkspaceError.invalidArgument(message: "Prepared project directory is not normalized: \(prepared.project.dir)")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedDir, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceError.invalidArgument(message: "Project directory not found: \(normalizedDir)")
        }
        if try store.project(dir: normalizedDir) != nil { throw WorkspaceError.projectAlreadyExists(dir: normalizedDir) }
        var workspaceIsDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: prepared.defaultWorkspace.dir, isDirectory: &workspaceIsDir), workspaceIsDir.boolValue else {
            throw WorkspaceError.invalidArgument(message: "Default workspace directory not found: \(prepared.defaultWorkspace.dir)")
        }
        let record = try configuredProjectRecord(baseRecord: prepared.project, update: configure)
        let defaultWorkspace = WorkspaceRecord(
            id: prepared.defaultWorkspace.id, projectID: record.id, title: prepared.defaultWorkspace.title, dir: prepared.defaultWorkspace.dir,
            dirname: prepared.defaultWorkspace.dirname, branch: prepared.defaultWorkspace.branch,
            targetBranch: prepared.defaultWorkspace.targetBranch, isDefault: true, isArchived: false, isHidden: prepared.defaultWorkspace.isHidden,
            isRunning: false, lastLaunchedAt: nil, notes: prepared.defaultWorkspace.notes)
        try store.upsert(project: record)
        do {
            try store.upsert(workspace: defaultWorkspace)
            try seedWorkspaceSettings(project: record, workspace: defaultWorkspace)
            let appConfig = try store.appConfig()
            let portDefinitions = try store.workspacePortDefinitions(workspaceID: defaultWorkspace.id)
            _ = try PortAllocator(store: store).allocatePorts(
                workspaceID: defaultWorkspace.id, definitions: portDefinitions, range: appConfig.portRange)
            return record
        } catch {
            try? rollbackFailedImportedProjectCreation(project: record, workspaceDirectory: defaultWorkspace.dir)
            throw error
        }
    }

    public func discardPreparedGitProject(_ prepared: PreparedGitProjectImport) throws {
        try removePreparedManagedGitWorkspaceRootIfUnowned(project: prepared.project)
        try removePreparedManagedProjectDirectoryIfUnowned(project: prepared.project)
    }

    @discardableResult public func previewProjectConfig(projectID: String, update: (inout ProjectRecord) -> Void) throws -> ProjectRecord {
        guard let record = try store.project(id: projectID) else { throw WorkspaceError.missingProject(dir: projectID) }
        return try configuredProjectRecord(baseRecord: record, update: update)
    }

    public func updateProjectConfig(projectID: String, update: (inout ProjectRecord) -> Void) throws {
        _ = try updateProjectConfig(projectID: projectID, updateAllWorkspaces: false, update: update)
    }

    @discardableResult public func updateProjectConfig(projectID: String, updateAllWorkspaces: Bool, update: (inout ProjectRecord) -> Void) throws
        -> ProjectRecord
    {
        guard let originalProject = try store.project(id: projectID) else { throw WorkspaceError.missingProject(dir: projectID) }
        let updatedProject = try configuredProjectRecord(baseRecord: originalProject, update: update)
        guard updateAllWorkspaces else {
            try store.upsert(project: updatedProject)
            try ensureDefaultWorkspace(for: updatedProject)
            return updatedProject
        }

        try ensureDefaultWorkspace(for: originalProject)
        let workspaceSnapshots = try workspaceConfigurationSnapshots(projectID: projectID)
        do {
            try store.upsert(project: updatedProject)
            try applyProjectTemplateToAllWorkspaces(project: updatedProject)
        } catch {
            try restoreSpacesYAMLImportSnapshot(project: originalProject, workspaces: workspaceSnapshots)
            throw error
        }
        return updatedProject
    }

    public func spacesYAMLConfigURL(projectID: String) throws -> URL {
        guard let project = try store.project(id: projectID) else { throw WorkspaceError.missingProject(dir: projectID) }
        return try spacesYAMLConfigURL(project: project)
    }

    public func loadSpacesYAML(projectID: String) throws -> SpacesYAMLDocument {
        guard let project = try store.project(id: projectID) else { throw WorkspaceError.missingProject(dir: projectID) }
        let document = try SpacesYAMLService.load(from: spacesYAMLConfigURL(project: project))
        _ = try previewProjectConfig(projectID: projectID) { record in document.applying(to: &record) }
        return document
    }

    @discardableResult public func exportSpacesYAML(projectID: String) throws -> URL {
        guard let project = try store.project(id: projectID) else { throw WorkspaceError.missingProject(dir: projectID) }
        let url = try spacesYAMLConfigURL(project: project)
        try SpacesYAMLService.write(SpacesYAMLDocument(project: project), to: url)
        return url
    }

    @discardableResult public func importSpacesYAML(projectID: String, updateAllWorkspaces: Bool = false) throws -> ProjectRecord {
        let document = try loadSpacesYAML(projectID: projectID)
        return try applySpacesYAMLDocument(document, projectID: projectID, updateAllWorkspaces: updateAllWorkspaces)
    }

    @discardableResult public func applySpacesYAMLDocument(_ document: SpacesYAMLDocument, projectID: String, updateAllWorkspaces: Bool = false)
        throws -> ProjectRecord
    { try updateProjectConfig(projectID: projectID, updateAllWorkspaces: updateAllWorkspaces) { record in document.applying(to: &record) } }

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
        runSetupScript: Bool = true, allowRemoteBranchLookup: Bool = true, allowExistingBranchReuse: Bool = false,
        replaceExistingManagedDirectory: Bool = false
    ) throws -> WorkspaceRecord {
        guard let project = try store.project(id: projectID) else { throw WorkspaceError.missingProject(dir: projectID) }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw WorkspaceError.invalidArgument(message: "Workspace name is required.") }
        let trimmedDirectoryName = directoryName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacesExplicitManagedDirectory = replaceExistingManagedDirectory && trimmedDirectoryName?.isEmpty == false
        let trimmedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBranch: String?
        let resolvedTargetBranch: String?
        if project.isGitRepo {
            guard let trimmedBranch, !trimmedBranch.isEmpty else {
                throw WorkspaceError.invalidArgument(message: "Branch name is required for git projects.")
            }
            resolvedBranch = trimmedBranch
            resolvedTargetBranch = try resolveWorkspaceTargetBranch(project: project, targetBranch: targetBranch)
        } else {
            if let trimmedDirectoryName, !trimmedDirectoryName.isEmpty {
                throw WorkspaceError.invalidArgument(message: "Directory name override is only supported for git projects.")
            }
            resolvedBranch = nil
            resolvedTargetBranch = nil
        }
        if project.isGitRepo, let branchName = resolvedBranch {
            if let existing = try workspaceForBranch(projectID: projectID, branch: branchName) {
                if existing.isArchived {
                    guard allowExistingBranchReuse else {
                        throw WorkspaceError.invalidArgument(
                            message: "Branch '\(branchName)' already exists. Choose it from Existing branch or enter a different new branch name.")
                    }
                } else {
                    throw WorkspaceError.invalidArgument(message: "Branch '\(branchName)' is already used by workspace '\(existing.title)'.")
                }
            }
            let branchExists = try branchExistsForNewWorkspace(project: project, branch: branchName, allowRemoteBranchLookup: allowRemoteBranchLookup)
            if allowExistingBranchReuse, !branchExists {
                throw WorkspaceError.invalidArgument(
                    message: "Branch '\(branchName)' was not found. Choose an existing branch or switch to Create branch.")
            }
            if !allowExistingBranchReuse, branchExists {
                throw WorkspaceError.invalidArgument(
                    message: "Branch '\(branchName)' already exists. Choose it from Existing branch or enter a different new branch name.")
            }
        }
        if project.isGitRepo, let branchName = resolvedBranch, let existing = try archivedWorkspace(projectID: projectID, branch: branchName) {
            let revivedDir: String
            let revivedDirname: String?
            let revivedBranch: String?
            let dirname = try makeWorkspaceDirname(
                project: project, preferredExistingDirname: existing.dirname, requestedDirname: trimmedDirectoryName, excludingDirname: nil,
                excludingFilesystemDirname: replacesExplicitManagedDirectory ? trimmedDirectoryName : nil)
            revivedDirname = dirname
            let worktreeRoot = try worktreeRoot(project: project)
            try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
            revivedDir = worktreeRoot.appendingPathComponent(dirname, isDirectory: true).path
            try replaceManagedWorkspaceDirectoryIfNeeded(path: revivedDir, allowReplacement: replacesExplicitManagedDirectory)
            if !FileManager.default.fileExists(atPath: revivedDir) {
                try git.createWorktree(
                    path: project.dir, worktreePath: revivedDir, branch: branchName, targetBranch: resolvedTargetBranch,
                    allowRemoteBranchLookup: allowRemoteBranchLookup)
            }
            revivedBranch = branchName
            let revived = WorkspaceRecord(
                id: existing.id, projectID: project.id, title: trimmedName, dir: revivedDir, dirname: revivedDirname, branch: revivedBranch,
                targetBranch: existing.targetBranch ?? resolvedTargetBranch, isDefault: false, isArchived: false, isHidden: existing.isHidden,
                isRunning: false, lastLaunchedAt: nil)
            try store.upsert(workspace: revived)
            try seedWorkspaceSettings(project: project, workspace: revived)
            try initializeWorkspaceRuntime(project: project, workspace: revived, runSetupScript: runSetupScript)
            return revived
        }
        if !project.isGitRepo, let existing = try archivedWorkspace(projectID: projectID, dir: project.dir) {
            let revived = WorkspaceRecord(
                id: existing.id, projectID: project.id, title: trimmedName, dir: project.dir, dirname: existing.dirname, branch: nil,
                targetBranch: nil, isDefault: false, isArchived: false, isHidden: existing.isHidden, isRunning: false, lastLaunchedAt: nil)
            try store.upsert(workspace: revived)
            try seedWorkspaceSettings(project: project, workspace: revived)
            try initializeWorkspaceRuntime(project: project, workspace: revived, runSetupScript: runSetupScript)
            return revived
        }
        let workspaceDir: String
        let workspaceDirname: String?
        let workspaceBranch: String?
        if project.isGitRepo {
            guard let branchName = resolvedBranch else { throw WorkspaceError.invalidArgument(message: "Branch name is required for git projects.") }
            let dirname = try makeWorkspaceDirname(
                project: project, preferredExistingDirname: nil, requestedDirname: trimmedDirectoryName, excludingDirname: nil,
                excludingFilesystemDirname: replacesExplicitManagedDirectory ? trimmedDirectoryName : nil)
            workspaceDirname = dirname
            let worktreeRoot = try worktreeRoot(project: project)
            try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
            workspaceDir = worktreeRoot.appendingPathComponent(dirname, isDirectory: true).path
            try replaceManagedWorkspaceDirectoryIfNeeded(path: workspaceDir, allowReplacement: replacesExplicitManagedDirectory)
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
        throw WorkspaceError.invalidArgument(message: "Target branch is required for git projects.")
    }

    public func createWorkspaceFromWorktree(worktreePath: String, name: String? = nil) throws -> WorkspaceRecord {
        let normalizedWorktreePath = normalizePath(worktreePath)
        guard FileManager.default.fileExists(atPath: normalizedWorktreePath) else {
            throw WorkspaceError.invalidArgument(message: "Worktree path does not exist: \(normalizedWorktreePath)")
        }
        guard git.isRepo(path: normalizedWorktreePath) else {
            throw WorkspaceError.invalidArgument(message: "Path is not a git repository: \(normalizedWorktreePath)")
        }
        let gitCommonDirOutput = try git.runGitAndCapture(["-C", normalizedWorktreePath, "rev-parse", "--git-common-dir"])
        let gitCommonDir = gitCommonDirOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let gitCommonDirURL = URL(fileURLWithPath: gitCommonDir, relativeTo: URL(fileURLWithPath: normalizedWorktreePath)).standardized
        let gitRoot = normalizePath(gitCommonDirURL.deletingLastPathComponent().path)
        guard let project = try store.project(dir: gitRoot) else {
            throw WorkspaceError.invalidArgument(
                message: "Project not found for git root: \(gitRoot). Add the project in the app before importing this workspace.")
        }
        if let existing = try store.workspace(dir: normalizedWorktreePath) {
            if existing.isArchived {
                throw WorkspaceError.invalidArgument(
                    message: "Workspace already exists but is archived: \(existing.title). Unarchive it or use a different worktree.")
            }
            throw WorkspaceError.invalidArgument(message: "Workspace already exists: \(existing.title)")
        }
        let branchOutput = try git.runGitAndCapture(["-C", normalizedWorktreePath, "rev-parse", "--abbrev-ref", "HEAD"])
        let branch = branchOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let inferredName: String
        if let providedName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !providedName.isEmpty {
            inferredName = providedName
        } else {
            inferredName = branch
        }
        if let existing = try workspaceForBranch(projectID: project.id, branch: branch) {
            if existing.isArchived {
                throw WorkspaceError.invalidArgument(
                    message: "Workspace already exists for archived branch '\(branch)': \(existing.title). Unarchive it or use a different worktree.")
            }
            throw WorkspaceError.invalidArgument(message: "Workspace already exists for branch '\(branch)': \(existing.title)")
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
            guard let project = try store.project(id: projectID) else { throw WorkspaceError.missingProject(dir: projectID) }
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
                        lastLaunchedAt: workspace.lastLaunchedAt, notes: workspace.notes)
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

    private func workspaceForBranch(projectID: String, branch: String) throws -> WorkspaceRecord? {
        try store.workspaces(projectID: projectID, includeArchived: true).first(where: { $0.branch == branch })
    }

    private func archivedWorkspace(projectID: String, branch: String) throws -> WorkspaceRecord? {
        try store.workspaces(projectID: projectID, includeArchived: true).first(where: { $0.branch == branch && $0.isArchived })
    }

    private func archivedWorkspace(projectID: String, dir: String) throws -> WorkspaceRecord? {
        try store.workspaces(projectID: projectID, includeArchived: true).first(where: { $0.dir == dir && $0.isArchived })
    }

    private func branchExistsForNewWorkspace(project: ProjectRecord, branch: String, allowRemoteBranchLookup: Bool) throws -> Bool {
        if git.branchExists(path: project.dir, branch: branch) { return true }
        guard allowRemoteBranchLookup else { return false }
        return try git.remoteBranchLookupStatus(path: project.dir, branch: branch) == .exists
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
            return gitRoot == project.dir
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
            guard !workspace.isArchived else { throw WorkspaceError.invalidArgument(message: "Workspace is archived.") }
            try validateWorkspaceFocusNames(workspaceID: workspace.id)
            let hasTrackedRuntime = try hasTrackedRuntimeIndicators(workspaceID: workspace.id)
            if workspace.isRunning || hasTrackedRuntime {
                if restartIfRunning {
                    _ = try stopWorkspaceUnlocked(workspaceID: workspaceID)
                    try launchWorkspaceUnlocked(workspaceID: workspaceID, background: background)
                } else {
                    try refreshProcessStatuses(workspaceID: workspaceID, ignoreStartupGracePeriod: true)
                    try restartExitedProcesses(workspaceID: workspaceID, background: background)
                    if try hasTrackedRuntimeIndicators(workspaceID: workspaceID) { try markWorkspaceRunningIfNeeded(workspaceID: workspaceID) }
                }
                return
            }
            try launchWorkspaceUnlocked(workspaceID: workspaceID, background: background)
        }
    }

    private func launchWorkspaceUnlocked(workspaceID: String, background: Bool = false) throws {
        let (_, initialWorkspace) = try resolveWorkspace(id: workspaceID)
        guard !initialWorkspace.isArchived else { throw WorkspaceError.invalidArgument(message: "Workspace is archived.") }
        try triggerDeferredWorkspaceSetupIfNeeded(workspaceID: workspaceID)
        try waitForWorkspaceSetupToComplete(workspaceID: workspaceID)
        try requireWorkspaceSetupSucceeded(workspaceID: workspaceID)
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let hasTrackedRuntime = try hasTrackedRuntimeIndicators(workspaceID: workspace.id)
        guard !(workspace.isRunning || hasTrackedRuntime) else {
            throw WorkspaceError.invalidArgument(message: "Workspace is already running. Use restart.")
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
        let shouldReleaseReservedPortsForLaunch = !(config?.processes.isEmpty ?? true)
        if shouldReleaseReservedPortsForLaunch {
            // Workspace port assignments remain pinned in the store until archive, but
            // the placeholder reservation sockets must step aside while a real process
            // binds the port during launch.
            PortReserver.shared.releasePorts(workspaceID: workspace.id)
        }
        var shouldRestoreReservedPorts = shouldReleaseReservedPortsForLaunch
        defer { if shouldRestoreReservedPorts { try? PortAllocator(store: store).reserveExistingPorts(workspaceID: workspace.id) } }

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
                terminalNativeID: window.terminalNativeID, terminalContainerID: window.terminalContainerID, role: window.role, orderIndex: index,
                lastSeenAt: window.lastSeenAt)
            index += 1
            try store.upsert(window: stored)
        }

        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: nowISO8601())
        shouldRestoreReservedPorts = false
    }

    private func triggerDeferredWorkspaceSetupIfNeeded(workspaceID: String) throws {
        let setupState = try workspaceSetupState(workspaceID: workspaceID)
        guard setupState.status == .pending else { return }
        do { try runWorkspaceSetup(workspaceID: workspaceID) } catch let error as WorkspaceError {
            if case .invalidArgument(let message) = error, message == "Workspace setup is already in progress." { return }
            throw error
        }
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
        var closedManagedTerminalWindowIDs = Set<Int>()
        var closedBuiltInTerminalSessionIDs = Set<String>()
        var skippedStopScriptBecauseWorkspaceDirectoryMissing = false
        for process in processes {
            if isManagedTerminalApp(process.terminalApp) {
                if let sessionID = process.terminalNativeID ?? process.terminalTrackingID, !sessionID.isEmpty {
                    terminateBuiltInTerminalSession(sessionID)
                    closedBuiltInTerminalSessionIDs.insert(sessionID)
                }
                if let windowID = process.windowID { closedManagedTerminalWindowIDs.insert(windowID) }
                if let pid = resolvedRuntimePID(for: process) { terminateProcessGroup(pid: pid) }
            } else if let pid = resolvedRuntimePID(for: process) {
                terminateProcessGroup(pid: pid)
            }
        }
        for agent in try store.agentWindows(workspaceID: workspace.id) {
            if let sessionID = agent.terminalNativeID ?? agent.terminalTrackingID, !sessionID.isEmpty {
                terminateBuiltInTerminalSession(sessionID)
                closedBuiltInTerminalSessionIDs.insert(sessionID)
            }
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
                if let windowID = window.windowID, closedManagedTerminalWindowIDs.contains(windowID) { continue }
                guard let sessionID = normalizedTerminalSessionID(window.terminalNativeID ?? window.terminalTrackingID) else { continue }
                if !closedBuiltInTerminalSessionIDs.contains(sessionID) {
                    terminateBuiltInTerminalSession(sessionID)
                    closedBuiltInTerminalSessionIDs.insert(sessionID)
                }
                continue
            }
            if let id = window.windowID { _ = try? yabai.closeWindow(id: id) }
        }
        try store.deleteRunningProcesses(workspaceID: workspace.id)
        try store.deleteWindows(workspaceID: workspace.id)
        try store.deleteAgentWindows(workspaceID: workspace.id)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: false, launchedAt: workspace.lastLaunchedAt)
        try PortAllocator(store: store).reserveExistingPorts(workspaceID: workspace.id)
        return WorkspaceStopOutcome(skippedStopScriptBecauseWorkspaceDirectoryMissing: skippedStopScriptBecauseWorkspaceDirectoryMissing)
    }

    public func archiveWorkspace(workspaceID: String, deleteLocalBranch: Bool = false, deleteRemoteBranch: Bool = false) throws
        -> WorkspaceArchiveOutcome
    {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            try archiveWorkspaceUnlocked(workspaceID: workspaceID, deleteLocalBranch: deleteLocalBranch, deleteRemoteBranch: deleteRemoteBranch)
        }
    }

    private func archiveWorkspaceUnlocked(workspaceID: String, deleteLocalBranch: Bool, deleteRemoteBranch: Bool) throws -> WorkspaceArchiveOutcome {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isDefault else { throw WorkspaceError.invalidArgument(message: "Default workspace cannot be archived.") }
        _ = try stopWorkspaceUnlocked(workspaceID: workspaceID)
        try store.deleteAgentWindows(workspaceID: workspaceID)
        if project.isGitRepo {
            do { try git.removeWorktree(path: project.dir, worktreePath: workspace.dir) } catch { if !isMissingWorktreeError(error) { throw error } }
        }
        try PortAllocator(store: store).releasePorts(workspaceID: workspace.id)
        try store.updateWorkspaceArchived(id: workspace.id, isArchived: true)
        let notice = try branchDeletionNotice(
            project: project, workspace: workspace, deleteLocalBranch: deleteLocalBranch, deleteRemoteBranch: deleteRemoteBranch)
        if try shouldClearArchivedWorkspaceBranchIdentity(
            project: project, workspace: workspace, deleteLocalBranch: deleteLocalBranch, deleteRemoteBranch: deleteRemoteBranch)
        {
            try store.updateWorkspaceBranch(id: workspace.id, branch: nil)
        }
        return WorkspaceArchiveOutcome(notice: notice)
    }

    private func branchDeletionNotice(project: ProjectRecord, workspace: WorkspaceRecord, deleteLocalBranch: Bool, deleteRemoteBranch: Bool) throws
        -> String?
    {
        guard project.isGitRepo else { return nil }
        guard deleteLocalBranch || deleteRemoteBranch else { return nil }
        guard let branch = workspace.branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty else {
            return "Workspace archived, but Spaces could not delete branches because no branch name was recorded."
        }
        if isProtectedBranchName(branch) { return "Workspace archived, but Spaces skipped branch deletion because '\(branch)' is protected." }

        var notices: [String] = []
        if deleteRemoteBranch {
            do {
                if try git.deleteRemoteBranch(path: project.dir, branch: branch) {
                    notices.append("Deleted remote branch '\(branch)'.")
                } else {
                    notices.append("Remote branch '\(branch)' was not found.")
                }
            } catch { notices.append("Failed to delete remote branch '\(branch)': \(error.localizedDescription)") }
        }
        if deleteLocalBranch {
            do {
                if try git.deleteBranch(path: project.dir, branch: branch) {
                    notices.append("Deleted local branch '\(branch)'.")
                } else {
                    notices.append("Local branch '\(branch)' was not found.")
                }
            } catch { notices.append("Failed to delete local branch '\(branch)': \(error.localizedDescription)") }
        }
        guard !notices.isEmpty else { return nil }
        return notices.joined(separator: " ")
    }

    private func shouldClearArchivedWorkspaceBranchIdentity(
        project: ProjectRecord, workspace: WorkspaceRecord, deleteLocalBranch: Bool, deleteRemoteBranch: Bool
    ) throws -> Bool {
        guard project.isGitRepo else { return false }
        guard deleteLocalBranch || deleteRemoteBranch else { return false }
        guard let branch = workspace.branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty else { return false }
        guard !git.branchExists(path: project.dir, branch: branch) else { return false }
        guard let remoteMissing = try? git.remoteBranchLookupStatus(path: project.dir, branch: branch) == .missing else { return false }
        return remoteMissing
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
                } else if exitedProcessCount > 0 || waitingAgentWindowCount > 0 {
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
            throw WorkspaceError.invalidArgument(message: "Workspace action is already in progress.")
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
            for workspace in workspaces { if try refreshProcessStatuses(workspaceID: workspace.id, project: project) { didUpdate = true } }
        }
        if try reconcileTerminalForegroundAgentClassifications() { didUpdate = true }
        return didUpdate
    }

    @discardableResult public func reconcileTerminalForegroundAgentClassifications() throws -> Bool {
        let liveSessions = try TerminalSessionCatalog.listLiveSessions()
        guard !liveSessions.isEmpty else { return false }
        var didMutate = false
        for session in liveSessions where session.launchConfiguration.backend == .ghosttyEmbedded {
            let sessionID = session.sessionID
            let ownership = try builtInTerminalSessionOwnership(sessionID: sessionID)
            if builtInTerminalSessionHasConfiguredOwner(ownership) { continue }
            guard let workspace = try workspaceForBuiltInTerminalSession(sessionID: sessionID, ownership: ownership) else { continue }
            guard let existingAgent = try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: sessionID) else {
                if let detectedAgent = adHocDetectedForegroundAgent(from: session.runtimeState) {
                    try upsertAdHocDetectedAgent(
                        existing: nil, detectedAgent: detectedAgent, workspace: workspace, sessionID: sessionID, runtimeState: session.runtimeState)
                    didMutate = true
                }
                continue
            }
            guard let detectedAgent = adHocDetectedForegroundAgent(from: session.runtimeState) else {
                if try updateAdHocAgentRuntimeTargetDetail(existingAgent, displayCommand: nil) { didMutate = true }
                if try adHocAgentIsDetectorOwned(existingAgent, sessionID: sessionID) {
                    try store.deleteAgentWindow(id: existingAgent.id)
                    didMutate = true
                }
                continue
            }
            if try upsertAdHocDetectedAgent(
                existing: existingAgent, detectedAgent: detectedAgent, workspace: workspace, sessionID: sessionID, runtimeState: session.runtimeState)
            {
                didMutate = true
            }
        }
        return didMutate
    }

    private func adHocDetectedForegroundAgent(from runtimeState: TerminalSessionRuntimeState) -> (label: String, displayCommand: String?)? {
        guard let kind = runtimeState.foregroundDetectedAgentKind else { return nil }
        let label = runtimeState.foregroundDisplayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayCommand = runtimeState.foregroundDisplayCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (label.flatMap { $0.isEmpty ? nil : $0 } ?? kind.displayLabel, displayCommand.flatMap { $0.isEmpty ? nil : $0 })
    }

    @discardableResult private func upsertAdHocDetectedAgent(
        existing: AgentWindowRecord?, detectedAgent: (label: String, displayCommand: String?), workspace: WorkspaceRecord, sessionID: String,
        runtimeState _: TerminalSessionRuntimeState
    ) throws -> Bool {
        let terminalWindow = try store.windows(workspaceID: workspace.id).first { window in
            window.role == "terminal" && terminalHost(for: window.app) == .spaces && terminalSessionID(for: window) == sessionID
        }
        let terminalTarget = TerminalTargetRecord(
            runtimeTargetID: existing?.runtimeTargetID ?? terminalWindow?.id, windowID: terminalWindow?.windowID ?? existing?.windowID,
            trackingID: sessionID)
        let now = nowISO8601()
        let resolvedLabel = try resolvedAdHocDetectedAgentLabel(
            existing: existing, detectedLabel: detectedAgent.label, workspaceID: workspace.id, sessionID: sessionID)
        let record = AgentWindowRecord(
            id: existing?.id ?? adHocDetectedAgentID(sessionID: sessionID), workspaceID: workspace.id, provider: .spaces, label: resolvedLabel,
            runtimeTargetID: existing?.runtimeTargetID ?? terminalWindow?.id, terminalTarget: terminalTarget, sessionKey: existing?.sessionKey,
            claimedLauncherID: nil, claimedLauncherName: nil, status: existing?.status ?? .idle, createdAt: existing?.createdAt ?? now, updatedAt: now
        )
        var nextAgentWindows = try store.agentWindows(workspaceID: workspace.id)
        if let existingRecordIndex = nextAgentWindows.firstIndex(where: { $0.id == record.id }) {
            nextAgentWindows[existingRecordIndex] = record
        } else {
            nextAgentWindows.append(record)
        }
        try validateWorkspaceFocusNames(
            workspaceID: workspace.id, processes: try store.workspaceProcesses(workspaceID: workspace.id),
            browserSessions: try store.workspaceBrowserSessions(workspaceID: workspace.id), agentWindows: nextAgentWindows)

        var didMutate = false
        if adHocAgent(existing, differsFrom: record) {
            try store.upsertAgentWindow(record)
            didMutate = true
        }
        let persistedRecord = try store.agentWindow(workspaceID: workspace.id, terminalTrackingID: sessionID) ?? record
        if try updateAdHocAgentRuntimeTargetDetail(persistedRecord, displayCommand: detectedAgent.displayCommand) { didMutate = true }
        return didMutate
    }

    private func adHocDetectedAgentID(sessionID: String) -> String { "terminal-agent-\(sessionID)" }

    private func adHocAgentIsDetectorOwned(_ agent: AgentWindowRecord, sessionID: String) throws -> Bool {
        guard agent.id == adHocDetectedAgentID(sessionID: sessionID) else { return false }
        return try !store.agentSessionHasEventSource(id: agent.id, source: "spaces_signal")
    }

    private func resolvedAdHocDetectedAgentLabel(existing: AgentWindowRecord?, detectedLabel: String, workspaceID: String, sessionID: String) throws
        -> String?
    {
        if let existing, try !adHocAgentIsDetectorOwned(existing, sessionID: sessionID) {
            let existingLabel = existing.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existingLabel, !existingLabel.isEmpty { return existing.label }
        }
        return try uniqueAgentFocusLabel(workspaceID: workspaceID, preferredLabel: detectedLabel, excludingAgentWindowID: existing?.id)
    }

    private func adHocAgent(_ existing: AgentWindowRecord?, differsFrom expected: AgentWindowRecord) -> Bool {
        guard let existing else { return true }
        if existing.provider != expected.provider { return true }
        if existing.workspaceID != expected.workspaceID { return true }
        if existing.label != expected.label { return true }
        if existing.runtimeTargetID != expected.runtimeTargetID { return true }
        if existing.terminalTrackingID != expected.terminalTrackingID { return true }
        if existing.windowID != expected.windowID { return true }
        if existing.sessionKey != expected.sessionKey { return true }
        if existing.status != expected.status { return true }
        return false
    }

    @discardableResult private func updateAdHocAgentRuntimeTargetDetail(_ agent: AgentWindowRecord, displayCommand: String?) throws -> Bool {
        let targetID = try store.agentSessionRuntimeTargetID(id: agent.id) ?? agent.runtimeTargetID
        guard let targetID else { return false }
        guard let window = try store.windows(workspaceID: agent.workspaceID).first(where: { $0.id == targetID }) else { return false }
        let nextDetail = adHocAgentRuntimeDetail(label: agent.label, displayCommand: displayCommand)
        guard window.detail != nextDetail else { return false }
        try store.upsert(
            window: WindowRecord(
                id: window.id, workspaceID: window.workspaceID, app: window.app, name: window.name, detail: nextDetail, targetURL: window.targetURL,
                windowID: window.windowID, terminalTrackingID: window.terminalTrackingID, terminalNativeID: window.terminalNativeID,
                terminalContainerID: window.terminalContainerID, role: window.role, orderIndex: window.orderIndex, lastSeenAt: nowISO8601()))
        return true
    }

    private func adHocAgentRuntimeDetail(label: String?, displayCommand: String?) -> String? {
        guard let command = displayCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return nil }
        let normalizedCommand = command.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedLabel = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard normalizedCommand != normalizedLabel else { return nil }
        return command
    }

    private func preservesForegroundAgentCommandDetail(_ window: WindowRecord) -> Bool {
        guard window.role == "terminal", terminalHost(for: window.app) == .spaces, let sessionID = terminalSessionID(for: window) else {
            return false
        }
        guard terminalSessionLaunchConfiguration(sessionID: sessionID)?.kind == .shell else { return false }
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), runtimeState.foregroundDetectedAgentKind != nil
        else { return false }
        return ((try? store.agentWindows(workspaceID: window.workspaceID)) ?? []).contains { builtInTerminalSessionID(for: $0) == sessionID }
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
            if let runtimeState = resolvedBuiltInSessionRuntimeState(for: process), runtimeState.state != .running {
                let updatedProcess = RunningProcessRecord(
                    id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                    terminalApp: process.terminalApp, windowID: process.windowID, terminalTrackingID: process.terminalTrackingID,
                    terminalNativeID: process.terminalNativeID, terminalContainerID: process.terminalContainerID,
                    pid: runtimeState.childPID.map(Int.init) ?? process.pid, status: .exited, logPath: process.logPath,
                    lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: runtimeState.exitedAt ?? nowISO8601())
                try store.upsert(runningProcess: updatedProcess)
                didUpdate = true
                try handleProcessExit(workspaceID: workspace.id, process: updatedProcess, project: project, workspace: workspace)
                continue
            }
            guard let pid = resolvedRuntimePID(for: process) else { continue }
            if process.pid != pid {
                let updatedProcess = RunningProcessRecord(
                    id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                    terminalApp: process.terminalApp, windowID: process.windowID, terminalTrackingID: process.terminalTrackingID,
                    terminalNativeID: process.terminalNativeID, terminalContainerID: process.terminalContainerID, pid: pid, status: process.status,
                    logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: process.exitedAt)
                try store.upsert(runningProcess: updatedProcess)
                didUpdate = true
            }
            if !isProcessAlive(pid: pid) {
                let updatedProcess = RunningProcessRecord(
                    id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                    runtimeTargetID: process.runtimeTargetID, terminalApp: process.terminalApp, windowID: process.windowID,
                    terminalTrackingID: process.terminalTrackingID, terminalNativeID: process.terminalNativeID,
                    terminalContainerID: process.terminalContainerID, pid: process.pid, status: .exited, logPath: process.logPath,
                    lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: nowISO8601())
                try store.upsert(runningProcess: updatedProcess)
                didUpdate = true
                try handleProcessExit(workspaceID: workspace.id, process: updatedProcess, project: project, workspace: workspace)
            }
        }
        return didUpdate
    }
    private static func deliverUserNotification(title: String, body: String, subtitle: String? = nil) {
        guard NSClassFromString("XCTest") == nil else { return }
        let center = UNUserNotificationCenter.current()
        guard let authorizationStatus = currentNotificationAuthorizationStatus(center: center) else {
            fputs("spaces: Timed out waiting for notification settings\n", stderr)
            return
        }
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else {
            switch authorizationStatus {
            case .denied: fputs("spaces: Notification authorization denied; skipping delivery\n", stderr)
            case .notDetermined: fputs("spaces: Notification authorization not determined; skipping delivery\n", stderr)
            default: fputs("spaces: Notification authorization unavailable (\(authorizationStatus.rawValue)); skipping delivery\n", stderr)
            }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let subtitle { content.subtitle = subtitle }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let timeout = DispatchTime.now() + .seconds(5)
        let addSemaphore = DispatchSemaphore(value: 0)
        center.add(request) { error in
            if let error { fputs("spaces: Failed to deliver notification: \(error.localizedDescription)\n", stderr) }
            addSemaphore.signal()
        }
        guard addSemaphore.wait(timeout: timeout) == .success else {
            fputs("spaces: Timed out waiting for notification delivery\n", stderr)
            return
        }
    }

    public static func prepareUserNotificationAuthorization() {
        guard NSClassFromString("XCTest") == nil else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await notificationSettings(center: center)
            notificationAuthorizationCache.set(settings.authorizationStatus)
            guard settings.authorizationStatus == .notDetermined else { return }
            do {
                let granted = try await requestNotificationAuthorization(center: center)
                let updatedSettings = await notificationSettings(center: center)
                let resolvedStatus =
                    updatedSettings.authorizationStatus == .notDetermined
                    ? (granted ? UNAuthorizationStatus.authorized : .denied) : updatedSettings.authorizationStatus
                notificationAuthorizationCache.set(resolvedStatus)
            } catch { fputs("spaces: Failed to request notification authorization: \(error.localizedDescription)\n", stderr) }
        }
    }

    private static func currentNotificationAuthorizationStatus(center: UNUserNotificationCenter) -> UNAuthorizationStatus? {
        if let cached = notificationAuthorizationCache.get(), cached != .notDetermined { return cached }
        let statusBox = LockedNotificationAuthorizationStatus()
        let semaphore = DispatchSemaphore(value: 0)
        center.getNotificationSettings { settings in
            notificationAuthorizationCache.set(settings.authorizationStatus)
            statusBox.set(settings.authorizationStatus)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + .seconds(5)) == .success else { return nil }
        return statusBox.get()
    }

    private static func notificationSettings(center: UNUserNotificationCenter) async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in center.getNotificationSettings { settings in continuation.resume(returning: settings) } }
    }

    private static func requestNotificationAuthorization(center: UNUserNotificationCenter) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
            }
        }
    }

    private final class LockedNotificationAuthorizationStatus: @unchecked Sendable {
        private let lock = NSLock()
        private var status: UNAuthorizationStatus?

        func set(_ status: UNAuthorizationStatus) {
            lock.lock()
            self.status = status
            lock.unlock()
        }

        func get() -> UNAuthorizationStatus? {
            lock.lock()
            defer { lock.unlock() }
            return status
        }
    }
    private func handleProcessExit(workspaceID: String, process: RunningProcessRecord, project: ProjectRecord, workspace: WorkspaceRecord) throws {
        // Find the process template to get the on-exit behavior
        guard let config = try loadWorkspaceSettings(project: project, workspace: workspace) else { return }
        guard
            let processTemplate = config.processes.first(where: { template in
                if let templateID = process.templateID?.trimmingCharacters(in: .whitespacesAndNewlines), !templateID.isEmpty {
                    return template.id == templateID
                }
                return processKey(for: template) == process.templateName
            })
        else { return }
        switch processTemplate.onExit {
        case .none:
            // Do nothing - just log the exit
            break
        case .notify: notificationDeliverer("Process Exited", "Process '\(process.templateName)' has exited", nil)
        case .restart:
            // Restart the process
            fputs("spaces: Restarting process '\(process.templateName)' due to exit\n", stderr)
            notificationDeliverer("Process Restarting", "Process '\(process.templateName)' is being restarted", nil)
            try restartProcessInTerminal(workspaceID: workspaceID, process: process)
        }
    }
    private func restartExitedProcesses(workspaceID: String, background: Bool) throws {
        let processes = try store.runningProcesses(workspaceID: workspaceID)
        for process in processes where process.status == .exited {
            try restartProcessInTerminal(workspaceID: workspaceID, process: process, background: background)
        }
    }

    private func restartProcessInTerminal(
        workspaceID: String, process: RunningProcessRecord, templateOverride: ProcessTemplate? = nil, terminalHostOverride: TerminalHost? = nil,
        background: Bool = false
    ) throws {
        try requireWorkspaceSetupSucceeded(workspaceID: workspaceID)
        let previousSessionID = process.terminalNativeID ?? process.terminalTrackingID
        if ProcessInfo.processInfo.environment["DEBUG"] == "1" {
            fputs(
                "spaces: restart_process begin workspace=\(workspaceID) name=\(process.templateName) previous_session=\(previousSessionID ?? "-")\n",
                stderr)
        }
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        _ = try terminalHostOverride ?? configuredTerminalHost()
        let template = try templateOverride ?? configuredProcessTemplate(for: process, workspace: workspace, project: project)
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspaceID)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        _ = terminateProcessForRestart(process)
        terminateBuiltInTerminalSession(for: process)
        let command = try spacesTerminalCommand(template: template, env: env)
        let session = try launchSpacesTerminalSession(
            title: process.templateName, workingDirectory: workspace.dir, command: command, showMode: .owner, backend: .ghosttyEmbedded,
            readinessPolicy: .sessionReady, workspaceID: workspace.id, kind: .process)
        if ProcessInfo.processInfo.environment["DEBUG"] == "1" {
            fputs(
                "spaces: restart_process launched workspace=\(workspaceID) name=\(process.templateName) previous_session=\(previousSessionID ?? "-") new_session=\(session.sessionID)\n",
                stderr)
        }
        let now = nowISO8601()
        let restartedProcess = RunningProcessRecord(
            id: process.id, workspaceID: process.workspaceID, templateID: template.id, templateName: process.templateName, command: template.command,
            runtimeTargetID: process.runtimeTargetID, terminalApp: TerminalHost.spaces.appName, windowID: session.windowID,
            terminalTrackingID: session.sessionID, terminalNativeID: session.sessionID, terminalContainerID: nil, pid: session.childPID,
            status: .running, logPath: session.outputPath, lastOutputAt: nil, startedAt: now, exitedAt: nil)
        try store.upsert(runningProcess: restartedProcess)
        let existingWindows = try store.windows(workspaceID: workspace.id)
        let existingWindow = existingWindows.first(where: { matchesTrackedTerminalWindow($0, process: process) })
        let restoredWindow = WindowRecord(
            id: existingWindow?.id ?? process.id, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: process.templateName,
            detail: process.command, targetURL: nil, windowID: session.windowID, terminalTrackingID: session.sessionID,
            terminalNativeID: session.sessionID, terminalContainerID: nil, role: "terminal",
            orderIndex: existingWindow?.orderIndex ?? Self.nextWindowOrderIndex(existing: existingWindows, role: "terminal", orderOffset: 200),
            lastSeenAt: now)
        try store.upsert(window: restoredWindow)
    }

    private func terminateProcessForRestart(_ process: RunningProcessRecord) -> Bool {
        guard let pid = resolvedRuntimePID(for: process) else { return true }
        terminateProcessGroup(pid: pid)
        waitForProcessExit(pid: pid, timeout: 10.0)
        guard isProcessAlive(pid: pid) else { return true }
        fputs(
            "spaces: Process '\(process.templateName)' with pid \(pid) did not exit in time; restart will open a fresh Spaces terminal session\n",
            stderr)
        return false
    }

    public func windows(workspaceID: String) throws -> [WindowRecord] { try indexedWorkspaceWindows(workspaceID: workspaceID) }

    public struct RefreshResult: Sendable {
        public let didMutateDB: Bool
        public let trackedWindowCounts: [String: Int]
    }

    @discardableResult public func refreshWorkspaceWindows(workspaceID: String) throws -> Bool {
        _ = try indexedWorkspaceWindows(workspaceID: workspaceID)
        let refreshedTerminalTitles = try refreshUnmanagedTerminalWindowTitles(workspaceID: workspaceID)
        let pruned = try pruneMissingWindows(workspaceID: workspaceID)
        return refreshedTerminalTitles > 0 || pruned > 0
    }

    @discardableResult private func refreshUnmanagedTerminalWindowTitles(workspaceID: String) throws -> Int {
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
            let refreshedName = window.name
            let refreshedDetail = preservesForegroundAgentCommandDetail(window) ? window.detail : liveWindow.title
            let refreshedApp = isManagedTerminalApp(window.app) ? TerminalHost.spaces.appName : liveWindow.app
            guard window.name != refreshedName || window.detail != refreshedDetail || window.app != refreshedApp else { continue }
            let refreshedWindow = WindowRecord(
                id: window.id, workspaceID: window.workspaceID, app: refreshedApp, name: refreshedName, detail: refreshedDetail,
                targetURL: window.targetURL, windowID: windowID, terminalTrackingID: window.terminalTrackingID,
                terminalNativeID: window.terminalNativeID, terminalContainerID: window.terminalContainerID, role: window.role,
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
        guard !workspace.isArchived else { throw WorkspaceError.invalidArgument(message: "Workspace is archived.") }
        guard let editor = try store.appConfig().editor, editor != .none else {
            throw WorkspaceError.configError(message: "Preferred editor is not configured.")
        }
        try EditorLauncher.open(editor: editor, directory: workspace.dir)
    }

    @discardableResult public func openWorkspaceTerminal(workspaceID: String) throws -> String {
        let reservation = try reserveWorkspaceTerminalLaunch(workspaceID: workspaceID)
        try finishReservedWorkspaceTerminalLaunch(reservation)
        return reservation.sessionID
    }

    public func reserveWorkspaceTerminalLaunch(workspaceID: String) throws -> WorkspaceTerminalLaunchReservation {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isArchived else { throw WorkspaceError.invalidArgument(message: "Workspace is archived.") }
        let terminalHost = try configuredTerminalHost()
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspaceID)
        let sessionID = UUID().uuidString
        let env = terminalLaunchEnvironment(
            base: buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts).merging([Self.terminalTrackingIDEnvVar: sessionID]
            ) { _, new in new }, terminalHost: terminalHost, includeInheritedPath: false)
        let generatedTitle = try generatedAdHocTerminalWindowName(workspaceID: workspace.id)
        let command = commandPrefixedWithShellEnvironment(interactiveShellCommand(cwd: workspace.dir), env: env)
        let createdAt = nowISO8601()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: generatedTitle, workingDirectory: workspace.dir,
            shell: terminalShellPathOverride() ?? "/bin/zsh", command: command, createdAt: createdAt, workspaceID: workspace.id, kind: .shell)
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
        FileManager.default.createFile(atPath: paths.serviceLogPath, contents: nil)
        let existing = try store.windows(workspaceID: workspace.id)
        let nextOrder = Self.nextWindowOrderIndex(existing: existing, role: "terminal", orderOffset: 200)
        let windowRecordID = UUID().uuidString
        let appName = terminalAppName(for: terminalHost)
        try store.upsert(
            window: WindowRecord(
                id: windowRecordID, workspaceID: workspace.id, app: appName, name: generatedTitle, detail: nil, targetURL: nil, windowID: nil,
                terminalTrackingID: sessionID, terminalNativeID: sessionID, terminalContainerID: nil, role: "terminal", orderIndex: nextOrder,
                lastSeenAt: nowISO8601()))
        if !workspace.isRunning {
            let launchedAt = workspace.lastLaunchedAt ?? nowISO8601()
            try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: launchedAt)
        }
        return WorkspaceTerminalLaunchReservation(
            sessionID: sessionID, workspaceID: workspace.id, windowRecordID: windowRecordID, appName: appName, title: generatedTitle,
            launchConfiguration: launchConfiguration, createdAt: createdAt, orderIndex: nextOrder)
    }

    @discardableResult public func finishReservedWorkspaceTerminalLaunch(_ reservation: WorkspaceTerminalLaunchReservation) throws -> String {
        do {
            guard try reservedWorkspaceTerminalWindowExists(reservation) else { return reservation.sessionID }
            let session = try launchSpacesTerminalSession(
                title: reservation.launchConfiguration.title, workingDirectory: reservation.launchConfiguration.workingDirectory,
                command: reservation.launchConfiguration.command, showMode: .owner, backend: reservation.launchConfiguration.backend,
                readinessPolicy: .stableChildPID, sessionID: reservation.sessionID, lifetimePolicy: reservation.launchConfiguration.lifetimePolicy,
                workspaceID: reservation.launchConfiguration.workspaceID, kind: reservation.launchConfiguration.kind)
            guard try reservedWorkspaceTerminalWindowExists(reservation) else {
                builtInTerminalSessionTerminator(reservation.sessionID)
                return session.sessionID
            }
            let existingWindow = try store.windows(workspaceID: reservation.workspaceID).first { $0.id == reservation.windowRecordID }
            try store.upsert(
                window: WindowRecord(
                    id: reservation.windowRecordID, workspaceID: reservation.workspaceID, app: reservation.appName, name: reservation.title,
                    detail: nil, targetURL: nil, windowID: session.windowID ?? existingWindow?.windowID, terminalTrackingID: session.sessionID,
                    terminalNativeID: session.sessionID, terminalContainerID: nil, role: "terminal", orderIndex: reservation.orderIndex,
                    lastSeenAt: nowISO8601()))
            return session.sessionID
        } catch {
            try? store.deleteWindow(id: reservation.windowRecordID)
            builtInTerminalWindowCloser(reservation.sessionID)
            throw error
        }
    }

    private func reservedWorkspaceTerminalWindowExists(_ reservation: WorkspaceTerminalLaunchReservation) throws -> Bool {
        try store.windows(workspaceID: reservation.workspaceID).contains { $0.id == reservation.windowRecordID }
    }

    public func persistBuiltInTerminalWindowID(sessionID: String, windowID: Int) throws {
        guard windowID > 0, let workspaceID = try store.workspaceIDForTerminalSession(sessionID) else { return }
        guard (try? yabai.listWindows().contains { $0.id == windowID }) ?? false else { return }
        let now = nowISO8601()
        for window in try store.windows(workspaceID: workspaceID) where (window.terminalNativeID ?? window.terminalTrackingID) == sessionID {
            try store.upsert(
                window: WindowRecord(
                    id: window.id, workspaceID: window.workspaceID, app: window.app, name: window.name, detail: window.detail,
                    targetURL: window.targetURL, windowID: windowID, terminalTrackingID: window.terminalTrackingID,
                    terminalNativeID: window.terminalNativeID, terminalContainerID: window.terminalContainerID, role: window.role,
                    orderIndex: window.orderIndex, lastSeenAt: now))
        }
    }

    public func focusWorkspace(workspaceID: String) throws {
        let windows = try indexedWorkspaceWindows(workspaceID: workspaceID)
        var focused = false
        for window in windows {
            let ok = focusTrackedWindow(window, workspaceID: workspaceID, requestID: nil)
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
        let ok = try focusTrackedWindowOrRecoverBrowserWindow(windows[targetIndex], workspaceID: workspaceID, requestID: nil)
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
        guard !trimmedName.isEmpty else { throw WorkspaceError.invalidArgument(message: "Window name is required.") }
        let focusStartedAt = currentDate()
        let targets = try focusableWorkspaceTargets(workspaceID: workspaceID)
        guard let match = targets.first(where: { normalizedFocusName($0.name) == normalizedFocusName(trimmedName) }) else {
            throw WorkspaceError.invalidArgument(message: missingFocusNameMessage(name: trimmedName, availableNames: targets.map(\.name)))
        }

        switch match.target {
        case .agent(let record):
            let focused = try focusAgentWindowOrLaunchClaimedLauncher(record, requestID: nil)
            guard focused else { throw missingTrackedAgentError(record) }
            rememberNavigationTarget(.agent(record), workspaceID: workspaceID)
        case .browserSession(let targetURL): try focusWorkspaceBrowserSession(workspaceID: workspaceID, targetURL: targetURL)
        case .configuredProcess(let processName):
            throw WorkspaceError.invalidArgument(message: "Process window '\(processName)' is not currently running.")
        case .process(let process):
            let focused = try focusWorkspaceProcessRecord(process, workspaceID: workspaceID)
            guard focused else { throw missingTrackedProcessError(process, workspaceID: workspaceID) }
            rememberNavigationTarget(.process(process), workspaceID: workspaceID)
        case .window(let window):
            let focused = try focusTrackedWindowOrRecoverBrowserWindow(window, workspaceID: workspaceID, requestID: nil)
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
            let focused = try focusTrackedWindowOrRecoverBrowserWindow(window, workspaceID: workspaceID, requestID: nil)
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

    public func focusWorkspaceProcess(workspaceID: String, processID: String, requestID: String? = nil) throws {
        let focusStartedAt = currentDate()
        guard let process = try store.runningProcesses(workspaceID: workspaceID).first(where: { $0.id == processID }) else { return }
        let outcome = try focusWorkspaceProcessOutcome(process, workspaceID: workspaceID, requestID: requestID)
        guard outcome.focused else { throw missingTrackedProcessError(process, workspaceID: workspaceID) }
        rememberNavigationTarget(.process(process), workspaceID: workspaceID)
        try markWorkspaceRunningIfNeeded(workspaceID: workspaceID)
        try setActiveWorkspace(id: workspaceID)
        logPerfMetric(
            "process_focus", workspaceID: workspaceID, target: process.templateName, detail: "route=\(outcome.route)",
            elapsedMS: elapsedMS(since: focusStartedAt), success: true)
    }

    public func focusNextWindow(workspaceID: String) throws {
        _ = try focusWindowRelative(workspaceID: workspaceID, delta: 1, requestID: nil, preferredFocusedBuiltInTerminalSessionID: nil)
    }

    public func focusPreviousWindow(workspaceID: String) throws {
        _ = try focusWindowRelative(workspaceID: workspaceID, delta: -1, requestID: nil, preferredFocusedBuiltInTerminalSessionID: nil)
    }

    public func focusNextWindowHidesApp(workspaceID: String, requestID: String? = nil, preferredFocusedBuiltInTerminalSessionID: String? = nil) throws
        -> Bool
    {
        try focusWindowRelative(
            workspaceID: workspaceID, delta: 1, requestID: requestID,
            preferredFocusedBuiltInTerminalSessionID: preferredFocusedBuiltInTerminalSessionID)
    }

    public func focusPreviousWindowHidesApp(workspaceID: String, requestID: String? = nil, preferredFocusedBuiltInTerminalSessionID: String? = nil)
        throws -> Bool
    {
        try focusWindowRelative(
            workspaceID: workspaceID, delta: -1, requestID: requestID,
            preferredFocusedBuiltInTerminalSessionID: preferredFocusedBuiltInTerminalSessionID)
    }

    public func workspaceIDForFocusedWindow() throws -> String? {
        guard let focused = try yabai.focusedWindow() else { return nil }
        if focused.app == "Google Chrome", let workspaceID = try focusedChromeWorkspaceID(windowID: focused.id) { return workspaceID }
        if let workspaceID = try store.workspaceID(windowID: focused.id) { return workspaceID }
        return try store.workspaceIDForAgentWindow(yabaiWindowID: focused.id)
    }

    public func workspaceIDForTerminalSession(_ sessionID: String) throws -> String? { try store.workspaceIDForTerminalSession(sessionID) }

    @discardableResult public func stopBuiltInTerminalSessionClosedByUser(sessionID: String) throws -> Bool {
        guard let sessionID = normalizedTerminalSessionID(sessionID) else { return false }
        let ownership = try builtInTerminalSessionOwnership(sessionID: sessionID)
        guard !builtInTerminalSessionHasConfiguredOwner(ownership) else { return false }
        guard let workspace = try workspaceForBuiltInTerminalSession(sessionID: sessionID, ownership: ownership) else { return false }
        return try stopAdHocBuiltInTerminalSession(workspaceID: workspace.id, sessionID: sessionID)
    }

    @discardableResult public func stopAdHocBuiltInTerminalSession(sessionID: String) throws -> Bool {
        guard let sessionID = normalizedTerminalSessionID(sessionID), let workspace = try workspaceForBuiltInTerminalSession(sessionID: sessionID)
        else { return false }
        return try stopAdHocBuiltInTerminalSession(workspaceID: workspace.id, sessionID: sessionID)
    }

    @discardableResult public func stopAdHocBuiltInTerminalSession(workspaceID: String, sessionID: String) throws -> Bool {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            try stopAdHocBuiltInTerminalSessionUnlocked(workspaceID: workspaceID, sessionID: sessionID)
        }
    }

    @discardableResult public func removeAdHocBuiltInTerminalSession(sessionID: String) throws -> Bool {
        guard let sessionID = normalizedTerminalSessionID(sessionID) else { return false }
        let ownership = try builtInTerminalSessionOwnership(sessionID: sessionID)
        guard !builtInTerminalSessionHasConfiguredOwner(ownership) else { return false }
        let workspaceID: String?
        if let terminalWindowWorkspaceID = ownership.terminalWindowWorkspaceID {
            workspaceID = terminalWindowWorkspaceID
        } else {
            workspaceID = ownership.launchWorkspaceID
        }
        guard let workspaceID else { return false }
        let matchingWindowIDs = try store.windows(workspaceID: workspaceID).filter {
            $0.role == "terminal" && terminalHost(for: $0.app) == .spaces && ($0.terminalNativeID ?? $0.terminalTrackingID) == sessionID
        }.map(\.id)
        guard !matchingWindowIDs.isEmpty else { return false }
        for windowID in matchingWindowIDs { try store.deleteWindow(id: windowID) }
        try deleteAgentRows(forBuiltInTerminalSession: sessionID, workspaceID: workspaceID)
        try clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: workspaceID)
        return true
    }

    private func stopAdHocBuiltInTerminalSessionUnlocked(workspaceID: String, sessionID: String) throws -> Bool {
        guard let sessionID = normalizedTerminalSessionID(sessionID), let workspace = try store.workspace(id: workspaceID) else { return false }
        let ownership = try builtInTerminalSessionOwnership(sessionID: sessionID)
        guard !builtInTerminalSessionHasConfiguredOwner(ownership) else { return false }
        if let terminalWindowWorkspaceID = ownership.terminalWindowWorkspaceID {
            guard terminalWindowWorkspaceID == workspaceID else { return false }
        } else if let launchWorkspaceID = ownership.launchWorkspaceID {
            guard launchWorkspaceID == workspaceID else { return false }
        } else {
            guard terminalSession(sessionID: sessionID, belongsTo: workspace) else { return false }
        }
        let matchingWindowIDs = try store.windows(workspaceID: workspaceID).filter {
            $0.role == "terminal" && terminalHost(for: $0.app) == .spaces && terminalSessionID(for: $0) == sessionID
        }.map(\.id)
        terminateBuiltInTerminalSession(sessionID)
        for windowID in matchingWindowIDs { try store.deleteWindow(id: windowID) }
        try deleteAgentRows(forBuiltInTerminalSession: sessionID, workspaceID: workspaceID)
        try clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: workspaceID)
        return true
    }

    @discardableResult private func deleteAgentRows(forBuiltInTerminalSession sessionID: String, workspaceID: String) throws -> Int {
        let matchingAgents = try store.agentWindows(workspaceID: workspaceID).filter { builtInTerminalSessionID(for: $0) == sessionID }
        for agent in matchingAgents { try store.deleteAgentWindow(id: agent.id) }
        return matchingAgents.count
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

    private func focusWindowRelative(workspaceID: String, delta: Int, requestID: String?, preferredFocusedBuiltInTerminalSessionID: String?) throws
        -> Bool
    {
        let cycleStartedAt = currentDate()
        let direction = delta > 0 ? "next" : "previous"
        let targetsStartedAt = currentDate()
        let targets = try workspaceNavigationTargets(workspaceID: workspaceID, forCycling: true)
        logCycleProfile(
            "workspace=\(workspaceID) stage=targets direction=\(direction) count=\(targets.count) elapsed_ms=\(elapsedMS(since: targetsStartedAt))")
        guard !targets.isEmpty else { return false }
        let currentIndexStartedAt = currentDate()
        let currentIndex: Int?
        if let preferredFocusedBuiltInTerminalSessionID,
            let preferredIndex = preferredFocusedBuiltInTerminalTargetIndex(
                targets: targets, workspaceID: workspaceID, terminalSessionID: preferredFocusedBuiltInTerminalSessionID)
        {
            logCycleProfile(
                "workspace=\(workspaceID) stage=current_target_resolved path=app_terminal_session index=\(preferredIndex) elapsed_ms=\(elapsedMS(since: currentIndexStartedAt))"
            )
            currentIndex = preferredIndex
        } else {
            currentIndex =
                try currentFocusedNavigationTargetIndex(targets: targets, workspaceID: workspaceID)
                ?? windowNavigationCursor(workspaceID: workspaceID).flatMap { navigationTargetIndex(cursor: $0, targets: targets) }
        }
        logCycleProfile(
            "workspace=\(workspaceID) stage=current_target direction=\(direction) resolved_index=\(currentIndex.map(String.init) ?? "nil") elapsed_ms=\(elapsedMS(since: currentIndexStartedAt))"
        )
        let cycleOrdering = cycleTargetOrdering(workspaceID: workspaceID, targets: targets, currentIndex: currentIndex)
        let orderedTargets = cycleOrdering.indices.map { targets[$0] }
        let orderedCurrentIndex = cycleOrdering.currentIndex
        let targetIndex: Int
        if let orderedCurrentIndex {
            targetIndex = (orderedCurrentIndex + delta + orderedTargets.count) % orderedTargets.count
        } else if delta > 0 {
            targetIndex = 0
        } else {
            targetIndex = orderedTargets.count - 1
        }
        var resolvedTargetIndex = targetIndex
        var ok = false
        for attempt in 0..<orderedTargets.count {
            let candidateIndex = (targetIndex + (attempt * delta) + (orderedTargets.count * 4)) % orderedTargets.count
            let focusTargetStartedAt = currentDate()
            let candidateFocused = try focusNavigationTarget(
                orderedTargets[candidateIndex], workspaceID: workspaceID, requestID: requestID,
                sourceBuiltInTerminalSessionID: preferredFocusedBuiltInTerminalSessionID)
            logCycleProfile(
                "workspace=\(workspaceID) stage=focus_target direction=\(direction) attempt=\(attempt) index=\(candidateIndex) target=\(navigationTargetDebugName(orderedTargets[candidateIndex])) success=\(candidateFocused ? "1" : "0") elapsed_ms=\(elapsedMS(since: focusTargetStartedAt))"
            )
            guard candidateFocused else { continue }
            resolvedTargetIndex = candidateIndex
            ok = true
            break
        }
        if ok {
            let activeWorkspaceStartedAt = currentDate()
            rememberNavigationTarget(orderedTargets[resolvedTargetIndex], workspaceID: workspaceID, asCycleNavigation: true)
            setWindowNavigationCycleSession(
                workspaceID: workspaceID, orderedCursors: orderedTargets.compactMap(navigationCursor(for:)), currentIndex: resolvedTargetIndex)
            try setActiveWorkspace(id: workspaceID)
            logCycleProfile(
                "workspace=\(workspaceID) stage=set_active direction=\(direction) elapsed_ms=\(elapsedMS(since: activeWorkspaceStartedAt))")
        }
        logCycleProfile(
            "workspace=\(workspaceID) direction=\(direction) total_ms=\(elapsedMS(since: cycleStartedAt)) target=\(navigationTargetDebugName(orderedTargets[resolvedTargetIndex])) success=\(ok ? "1" : "0")"
        )
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        logPerfMetric(
            "window_cycle", workspaceID: workspaceID, target: navigationTargetDebugName(orderedTargets[resolvedTargetIndex]),
            detail: "direction=\(direction)\(requestDetail)", elapsedMS: elapsedMS(since: cycleStartedAt), success: ok)
        guard ok else { return false }
        return shouldHideAppAfterFocusingNavigationTarget(orderedTargets[resolvedTargetIndex])
    }

    private func currentFocusedNavigationTargetIndex(targets: [WorkspaceNavigationTarget], workspaceID: String) throws -> Int? {
        let resolutionStartedAt = currentDate()
        let focusedWindowStartedAt = currentDate()
        guard let focused = try yabai.focusedWindow() else {
            if let cursor = windowNavigationCursor(workspaceID: workspaceID),
                let cursorIndex = navigationTargetIndex(cursor: cursor, targets: targets)
            {
                logCycleProfile(
                    "workspace=\(workspaceID) stage=current_target_resolved path=cursor_fallback index=\(cursorIndex) elapsed_ms=\(elapsedMS(since: resolutionStartedAt))"
                )
                return cursorIndex
            }
            if let browserMatch = try currentFocusedBrowserNavigationTargetIndex(targets: targets, workspaceID: workspaceID) {
                logCycleProfile(
                    "workspace=\(workspaceID) stage=current_target_resolved path=browser_url index=\(browserMatch) elapsed_ms=\(elapsedMS(since: resolutionStartedAt))"
                )
                return browserMatch
            }
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
        if let browserMatch = try currentFocusedBrowserNavigationTargetIndex(targets: targets, workspaceID: workspaceID) {
            logCycleProfile(
                "workspace=\(workspaceID) stage=current_target_resolved path=browser_url index=\(browserMatch) elapsed_ms=\(elapsedMS(since: resolutionStartedAt))"
            )
            return browserMatch
        }
        logCycleProfile("workspace=\(workspaceID) stage=current_target_resolved path=none elapsed_ms=\(elapsedMS(since: resolutionStartedAt))")
        return nil
    }

    private func currentFocusedBrowserNavigationTargetIndex(targets: [WorkspaceNavigationTarget], workspaceID: String) throws -> Int? {
        guard chrome.isAvailable(), let activeURL = try chrome.frontmostActiveTabURL(), !activeURL.isEmpty else { return nil }

        let browserMatches = targets.enumerated().compactMap { entry -> (offset: Int, targetURL: String)? in
            guard let targetURL = navigationTargetBrowserURL(entry.element), !targetURL.isEmpty, activeURL.hasPrefix(targetURL) else { return nil }
            return (entry.offset, targetURL)
        }
        guard !browserMatches.isEmpty else { return nil }

        if let cursor = windowNavigationCursor(workspaceID: workspaceID),
            let cursorMatch = browserMatches.first(where: { navigationCursor(for: targets[$0.offset]) == cursor })
        {
            return cursorMatch.offset
        }

        return browserMatches.max(by: { $0.targetURL.count < $1.targetURL.count })?.offset
    }

    private func preferredFocusedBuiltInTerminalTargetIndex(targets: [WorkspaceNavigationTarget], workspaceID: String, terminalSessionID: String)
        -> Int?
    {
        let terminalMatches = targets.enumerated().filter { navigationTargetTerminalID($0.element) == terminalSessionID }
        guard !terminalMatches.isEmpty else { return nil }

        if let cursor = windowNavigationCursor(workspaceID: workspaceID),
            let cursorMatch = terminalMatches.first(where: { navigationCursor(for: $0.element) == cursor })
        {
            return cursorMatch.offset
        }

        if let session = windowNavigationCycleSession(workspaceID: workspaceID, now: currentDate()),
            let sessionIndices = sessionTargetIndices(session: session, targetCursors: targets.map(navigationCursor(for:))),
            session.currentIndex >= 0, session.currentIndex < sessionIndices.count
        {
            let sessionTarget = targets[sessionIndices[session.currentIndex]]
            if let sessionMatch = terminalMatches.first(where: { navigationCursor(for: $0.element) == navigationCursor(for: sessionTarget) }) {
                return sessionMatch.offset
            }
        }

        return terminalMatches.last?.offset
    }

    private func workspaceNavigationTargets(workspaceID: String, forCycling: Bool = false) throws -> [WorkspaceNavigationTarget] {
        let targetsStartedAt = currentDate()
        _ = forCycling
        let windows = try indexedWorkspaceWindows(workspaceID: workspaceID)
        let processes = try store.runningProcesses(workspaceID: workspaceID)
        let agentWindows = try store.agentWindows(workspaceID: workspaceID)
        let agentTerminalIDs = Set(agentWindows.compactMap { terminalTargetID(record: $0) })
        let processesByTerminalID: [String: [RunningProcessRecord]] = {
            var map: [String: [RunningProcessRecord]] = [:]
            for process in processes {
                guard let terminalID = terminalTargetID(process: process), !terminalID.isEmpty else { continue }
                map[terminalID, default: []].append(process)
            }
            return map.mapValues { value in value.sorted { $0.templateName.localizedStandardCompare($1.templateName) == .orderedAscending } }
        }()
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
            let windowTerminalID = terminalTargetID(window: window)
            let windowProcesses: [RunningProcessRecord]
            if window.role == "terminal" {
                if let matchedByWindowID = processesByWindowID[window.windowID ?? -1], !matchedByWindowID.isEmpty {
                    windowProcesses = matchedByWindowID
                } else if let windowTerminalID, let matchedByTerminalID = processesByTerminalID[windowTerminalID], !matchedByTerminalID.isEmpty {
                    windowProcesses = matchedByTerminalID
                } else {
                    windowProcesses = []
                }
            } else {
                windowProcesses = []
            }
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

    private func focusNavigationTarget(
        _ target: WorkspaceNavigationTarget, workspaceID: String, requestID: String?, sourceBuiltInTerminalSessionID: String?
    ) throws -> Bool {
        switch target {
        case .agent(let record): return try focusAgentWindowOrLaunchClaimedLauncher(record, requestID: requestID)
        case .browser(let window), .window(let window):
            return focusTrackedWindow(
                window, workspaceID: workspaceID, requestID: requestID, sourceBuiltInTerminalSessionID: sourceBuiltInTerminalSessionID)
        case .process(let process): return try focusWorkspaceProcessOutcome(process, workspaceID: workspaceID, requestID: requestID).focused
        }
    }

    private func shouldHideAppAfterFocusingNavigationTarget(_ target: WorkspaceNavigationTarget) -> Bool {
        switch target {
        case .agent: return false
        case .browser: return true
        case .process: return false
        case .window(let window): return window.app != TerminalHost.spaces.appName
        }
    }

    private func navigationCursor(for target: WorkspaceNavigationTarget) -> WorkspaceNavigationCursor? {
        switch target {
        case .agent(let record): return .agent(record.id)
        case .process(let process): return .process(process.id)
        case .browser(let window):
            if let browserURL = window.targetURL, !browserURL.isEmpty, let windowID = window.windowID {
                return .browserWindowURL(windowID, browserURL)
            }
            if let browserURL = window.targetURL, !browserURL.isEmpty { return .browserURL(browserURL) }
            if let windowID = window.windowID { return .window(windowID) }
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

    private func fallbackAgentFocusName(_ record: AgentWindowRecord) throws -> String? {
        let trackedWindow = try matchedTrackedWindowForAgent(
            workspaceID: record.workspaceID, provider: record.provider, terminalTrackingID: record.terminalTrackingID,
            yabaiWindowID: record.yabaiWindowID ?? record.windowID)
        if let title = sanitizedFocusName(trackedWindow?.name) { return sanitizedFocusName("Coding Agent \(title)") ?? title }
        if let detail = sanitizedFocusName(trackedWindow?.detail) { return sanitizedFocusName("Coding Agent \(detail)") ?? detail }
        return sanitizedFocusName("Coding Agent")
    }

    private func focusName(for target: WorkspaceNavigationTarget, workspaceID: String) throws -> String? {
        switch target {
        case .agent(let record):
            if let label = sanitizedFocusName(record.label) { return label }
            return try fallbackAgentFocusName(record)
        case .browser(let window): return sanitizedFocusName(window.name)
        case .process(let process): return sanitizedFocusName(process.templateName)
        case .window(let window): return sanitizedFocusName(window.name)
        }
    }

    private func cycleTargetOrdering(workspaceID: String, targets: [WorkspaceNavigationTarget], currentIndex: Int?) -> (
        indices: [Int], currentIndex: Int?
    ) {
        let targetCursors = targets.map(navigationCursor(for:))
        if let session = windowNavigationCycleSession(workspaceID: workspaceID, now: currentDate()),
            let sessionIndices = sessionTargetIndices(session: session, targetCursors: targetCursors)
        {
            let resolvedCurrentIndex =
                if let currentIndex, let cursor = targetCursors[currentIndex] {
                    sessionIndices.firstIndex(where: { targetCursors[$0] == cursor }) ?? session.currentIndex
                } else { session.currentIndex }
            return (sessionIndices, resolvedCurrentIndex)
        }

        let orderedIndices = Array(targets.indices)
        return (orderedIndices, currentIndex.flatMap { originalIndex in orderedIndices.firstIndex(of: originalIndex) })
    }

    private func sessionTargetIndices(session: WorkspaceNavigationCycleSession, targetCursors: [WorkspaceNavigationCursor?]) -> [Int]? {
        var remainingIndicesByCursor: [WorkspaceNavigationCursor: [Int]] = [:]
        for (index, cursor) in targetCursors.enumerated() {
            guard let cursor else { return nil }
            remainingIndicesByCursor[cursor, default: []].append(index)
        }
        var orderedIndices: [Int] = []
        for cursor in session.orderedCursors {
            guard var indices = remainingIndicesByCursor[cursor], let nextIndex = indices.first else { return nil }
            orderedIndices.append(nextIndex)
            indices.removeFirst()
            remainingIndicesByCursor[cursor] = indices.isEmpty ? nil : indices
        }
        for (_, indices) in remainingIndicesByCursor.sorted(by: { $0.value[0] < $1.value[0] }) { orderedIndices.append(contentsOf: indices) }
        return orderedIndices
    }

    private func rememberNavigationTarget(_ target: WorkspaceNavigationTarget, workspaceID: String, asCycleNavigation: Bool = false) {
        updateWindowNavigationState(navigationCursor(for: target), workspaceID: workspaceID, asCycleNavigation: asCycleNavigation)
    }

    private func updateWindowNavigationState(_ cursor: WorkspaceNavigationCursor?, workspaceID: String, asCycleNavigation: Bool) {
        windowNavigationLock.lock()
        defer { windowNavigationLock.unlock() }
        if let cursor {
            windowNavigationCursorByWorkspace[workspaceID] = cursor
            var history = windowNavigationHistoryByWorkspace[workspaceID] ?? []
            history.removeAll(where: { $0 == cursor })
            history.insert(cursor, at: 0)
            if history.count > windowNavigationHistoryLimit { history.removeLast(history.count - windowNavigationHistoryLimit) }
            windowNavigationHistoryByWorkspace[workspaceID] = history
            if !asCycleNavigation { windowNavigationCycleSessionByWorkspace.removeValue(forKey: workspaceID) }
        } else {
            windowNavigationCursorByWorkspace.removeValue(forKey: workspaceID)
            windowNavigationCycleSessionByWorkspace.removeValue(forKey: workspaceID)
        }
    }

    private func setWindowNavigationCycleSession(workspaceID: String, orderedCursors: [WorkspaceNavigationCursor], currentIndex: Int) {
        windowNavigationLock.lock()
        windowNavigationCycleSessionByWorkspace[workspaceID] = WorkspaceNavigationCycleSession(
            orderedCursors: orderedCursors, currentIndex: currentIndex, lastUsedAt: currentDate())
        windowNavigationLock.unlock()
    }

    private func windowNavigationHistory(workspaceID: String) -> [WorkspaceNavigationCursor] {
        windowNavigationLock.lock()
        defer { windowNavigationLock.unlock() }
        return windowNavigationHistoryByWorkspace[workspaceID] ?? []
    }

    private func windowNavigationCycleSession(workspaceID: String, now: Date) -> WorkspaceNavigationCycleSession? {
        windowNavigationLock.lock()
        defer { windowNavigationLock.unlock() }
        guard let session = windowNavigationCycleSessionByWorkspace[workspaceID] else { return nil }
        guard now.timeIntervalSince(session.lastUsedAt) <= windowNavigationCycleSessionTimeout else {
            windowNavigationCycleSessionByWorkspace.removeValue(forKey: workspaceID)
            return nil
        }
        return session
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
        // and `spaces open <name>` keep a stable one-name-to-one-row mapping.
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
        if let match = sessions.compactMap({ session -> (name: String, targetURL: String, score: Int)? in
            guard let score = browserURLMatchScore(targetURL, targetURL: session.targetURL) else { return nil }
            return (session.name, session.targetURL, score)
        }).max(by: { lhs, rhs in
            if lhs.score == rhs.score { return lhs.targetURL.count < rhs.targetURL.count }
            return lhs.score < rhs.score
        }) {
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
            throw WorkspaceError.invalidArgument(message: "\(kind) name is required.")
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
        throw WorkspaceError.invalidArgument(
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

    private func focusTrackedWindow(_ window: WindowRecord, workspaceID: String, requestID: String?, sourceBuiltInTerminalSessionID: String? = nil)
        -> Bool
    {
        let focusStartedAt = currentDate()
        let focused: Bool
        let focusedExistingWindow: Bool
        if window.role == "browser", let windowID = window.windowID {
            var browserFocusPath = "yabai"
            let focusedWindow: Bool
            if sourceBuiltInTerminalSessionID != nil, let requestID, let targetURL = window.targetURL, chrome.isAvailable() {
                let chromeFocusByWindowStartedAt = currentDate()
                let focusedByWindow = (try? focusScannedBrowserTab(workspaceID: workspaceID, targetURL: targetURL)) ?? false
                logBrowserFocus(
                    "workspace=\(workspaceID) path=chrome_scanned_tab_from_built_in window=\(windowID) success=\(focusedByWindow ? "1" : "0") elapsed_ms=\(elapsedMS(since: chromeFocusByWindowStartedAt)) request_id=\(requestID)"
                )
                if focusedByWindow {
                    focusedWindow = true
                    browserFocusPath = "chrome_scanned_tab_from_built_in"
                } else {
                    let chromeFocusByURLStartedAt = currentDate()
                    let focusedByURL = (try? chrome.focusFirstMatchingTab(urlPrefix: targetURL)) ?? false
                    logBrowserFocus(
                        "workspace=\(workspaceID) path=chrome_url_from_built_in target=\(targetURL) success=\(focusedByURL ? "1" : "0") elapsed_ms=\(elapsedMS(since: chromeFocusByURLStartedAt)) request_id=\(requestID)"
                    )
                    if focusedByURL {
                        focusedWindow = true
                        browserFocusPath = "chrome_url_from_built_in"
                    } else {
                        focusedWindow = (try? yabai.focusWindow(id: windowID)) ?? false
                    }
                }
            } else {
                focusedWindow = (try? yabai.focusWindow(id: windowID)) ?? false
            }
            if focusedWindow, chrome.isAvailable(), browserFocusPath == "yabai" {
                let chromeFocusStartedAt = currentDate()
                _ = try? chrome.focusFirstTabOfFrontWindow()
                browserFocusPath = "chrome_front_tab_1"
                logBrowserFocus(
                    "workspace=\(workspaceID) path=\(browserFocusPath) window=\(windowID) success=\(focusedWindow ? "1" : "0") elapsed_ms=\(elapsedMS(since: chromeFocusStartedAt)) request_id=\(requestID ?? "")"
                )
            }
            focused = focusedWindow
            focusedExistingWindow = focusedWindow
            logBrowserFocus(
                "workspace=\(workspaceID) path=\(browserFocusPath) window=\(windowID) success=\(focused ? "1" : "0") elapsed_ms=\(elapsedMS(since: focusStartedAt))"
            )
        } else {
            let trackingIdentity = resolvedFocusIdentity(for: window, workspaceID: workspaceID)
            let focusResult = focusManagedTerminal(
                terminalApp: window.app, providerIdentity: trackingIdentity, windowID: window.windowID, requestID: requestID)
            switch focusResult {
            case .existingWindow:
                focused = true
                focusedExistingWindow = true
            case .trackedTerminal:
                focused = true
                focusedExistingWindow = window.windowID != nil
            case .sessionRequest:
                focused = true
                focusedExistingWindow = false
            case .reboundSession(let capturedWindowID):
                focused = true
                focusedExistingWindow = false
                if terminalHost(for: window.app) == .spaces {
                    if let capturedWindowID {
                        try? persistBuiltInTerminalWindowBinding(window, windowID: capturedWindowID)
                    } else {
                        try? clearStaleBuiltInTerminalWindowBinding(window)
                    }
                }
            case .reopenedSession(let capturedWindowID):
                focused = true
                focusedExistingWindow = false
                if terminalHost(for: window.app) == .spaces {
                    if let capturedWindowID {
                        try? persistBuiltInTerminalWindowBinding(window, windowID: capturedWindowID)
                    } else {
                        try? clearStaleBuiltInTerminalWindowBinding(window)
                    }
                }
            case .unavailable:
                let fallbackFocused = (window.windowID.flatMap { try? yabai.focusWindow(id: $0) }) ?? false
                focused = fallbackFocused
                focusedExistingWindow = fallbackFocused
            }
        }
        guard let id = window.windowID else { return focused }
        if !focused, window.role == "browser", let targetURL = window.targetURL {
            try? markBrowserWindowMissing(workspaceID: workspaceID, targetURL: targetURL, windowID: id)
        }
        if focused, focusedExistingWindow, window.role == "terminal" { pulseTerminalWindowIfNeeded(windowID: id) }
        return focused
    }

    private func focusTrackedWindowOrRecoverBrowserWindow(_ window: WindowRecord, workspaceID: String, requestID: String?) throws -> Bool {
        let focused = focusTrackedWindow(window, workspaceID: workspaceID, requestID: requestID)
        guard !focused, window.role == "browser", let targetURL = window.targetURL else { return focused }
        try recoverMissingBrowserSession(workspaceID: workspaceID, targetURL: targetURL)
        return true
    }

    private func closeTrackedItermTerminalContainer(_ process: RunningProcessRecord) throws -> Bool {
        guard isManagedTerminalApp(process.terminalApp) else { return false }
        if terminalHost(for: process.terminalApp) == .spaces {
            guard let sessionID = process.terminalNativeID ?? process.terminalTrackingID, !sessionID.isEmpty else { return false }
            builtInTerminalWindowCloser(sessionID)
            return true
        }
        guard let windowID = process.windowID else { return false }
        return (try? yabai.closeWindow(id: windowID)) != nil
    }

    private func closeTrackedItermTerminalWindow(_ trackedWindow: WindowRecord) throws -> Bool {
        if terminalHost(for: trackedWindow.app) == .spaces {
            guard let sessionID = trackedWindow.terminalNativeID ?? trackedWindow.terminalTrackingID, !sessionID.isEmpty else { return false }
            builtInTerminalWindowCloser(sessionID)
            return true
        }
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
            terminalContainerID: existing.terminalContainerID, itermTabIndex: tabIndex, tmuxWindowID: existing.tmuxWindowID, role: existing.role,
            orderIndex: existing.orderIndex, lastSeenAt: nowISO8601())
        try store.upsert(window: updated)
    }

    private func tmuxSessionName(workspaceID: String) -> String { "spaces-\(workspaceID)" }

    private func terminalTargetID(process: RunningProcessRecord) -> String? {
        if let sessionID = process.terminalNativeID, !sessionID.isEmpty { return sessionID }
        return process.terminalTrackingKey
    }

    private func terminalTargetID(record: AgentWindowRecord) -> String? {
        if let sessionID = record.terminalNativeID, !sessionID.isEmpty { return sessionID }
        return record.terminalTrackingKey
    }

    private func terminalTargetID(window: WindowRecord) -> String? {
        if let sessionID = window.terminalNativeID, !sessionID.isEmpty { return sessionID }
        return window.terminalTrackingKey
    }

    private func configuredTerminalHost() throws -> TerminalHost { .spaces }

    private func terminalHost(for appName: String?) -> TerminalHost? {
        guard let appName else { return nil }
        return appName == TerminalHost.spaces.appName ? .spaces : nil
    }

    private func agentProvider(for _: TerminalHost) -> AgentProvider { .spaces }

    private func terminalAppName(for terminalHost: TerminalHost) -> String { terminalHost.appName }

    private func isManagedTerminalApp(_ appName: String?) -> Bool { terminalHost(for: appName) != nil }

    private func terminalAdapter(for terminalHost: TerminalHost) -> (any TerminalAdapter)? { terminalAdaptersByHost[terminalHost] }

    private func storedTerminalHookSessionID(terminalHost _: TerminalHost, handle: ManagedTerminalHandle) -> String? {
        handle.hookAttributionID ?? handle.providerIdentity?.sessionID
    }

    private func storedTerminalNativeID(terminalHost _: TerminalHost, handle: ManagedTerminalHandle) -> String? {
        return handle.providerIdentity?.sessionID
    }

    private func storedTerminalContainerID(terminalHost _: TerminalHost, handle _: ManagedTerminalHandle) -> String? { nil }

    private func resolvedFocusIdentity(for window: WindowRecord, workspaceID: String) -> TerminalTrackingIdentity? {
        if let terminalHost = terminalHost(for: window.app), terminalHost == .spaces, let focusIdentity = window.terminalFocusIdentity {
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

    private func focusManagedTerminal(terminalApp: String?, providerIdentity: TerminalTrackingIdentity?, windowID: Int?, requestID: String? = nil)
        -> ManagedTerminalFocusResult
    {
        guard let terminalHost = terminalHost(for: terminalApp) else { return .unavailable }
        if terminalHost == .spaces {
            let startedAt = currentDate()
            let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
            if case .session(let sessionID)? = providerIdentity {
                builtInTerminalWindowFocuser(sessionID, requestID)
                guard requestID == nil else {
                    logTerminalPerfMetric(
                        "built_in_terminal_focus_route", target: "session=\(sessionID)", detail: "stage=session_request\(requestDetail)",
                        elapsedMS: elapsedMS(since: startedAt), success: true)
                    return .sessionRequest
                }
                if let capturedWindowID = try? captureSummonedBuiltInTerminalWindowID(appName: terminalAppName(for: terminalHost)) {
                    if capturedWindowID != windowID {
                        logTerminalPerfMetric(
                            "built_in_terminal_focus_route", target: "session=\(sessionID)",
                            detail: "stage=rebound_session window=\(capturedWindowID)\(requestDetail)", elapsedMS: elapsedMS(since: startedAt),
                            success: true)
                        return .reboundSession(windowID: capturedWindowID)
                    }
                    logTerminalPerfMetric(
                        "built_in_terminal_focus_route", target: "session=\(sessionID)",
                        detail: "stage=existing_window window=\(capturedWindowID)\(requestDetail)", elapsedMS: elapsedMS(since: startedAt),
                        success: true)
                    return .existingWindow
                }
                if windowID != nil {
                    logTerminalPerfMetric(
                        "built_in_terminal_focus_route", target: "session=\(sessionID)", detail: "stage=reopened_session window=nil\(requestDetail)",
                        elapsedMS: elapsedMS(since: startedAt), success: true)
                    return .reopenedSession(windowID: nil)
                }
                logTerminalPerfMetric(
                    "built_in_terminal_focus_route", target: "session=\(sessionID)", detail: "stage=session_request\(requestDetail)",
                    elapsedMS: elapsedMS(since: startedAt), success: true)
                return .sessionRequest
            }
            if let windowID, (try? yabai.focusWindow(id: windowID)) ?? false {
                logTerminalPerfMetric(
                    "built_in_terminal_focus_route", target: "window=\(windowID)", detail: "stage=existing_window\(requestDetail)",
                    elapsedMS: elapsedMS(since: startedAt), success: true)
                return .existingWindow
            }
            return .unavailable
        }
        guard let terminalAdapter = terminalAdapter(for: terminalHost) else { return .unavailable }
        let hasPreciseTarget = providerIdentity != nil || windowID != nil
        guard hasPreciseTarget else { return .unavailable }
        let target = TerminalFocusTarget(providerIdentity: providerIdentity, windowID: windowID)
        return (try? terminalAdapter.focusTrackedTerminal(target)) == true ? .trackedTerminal : .unavailable
    }

    private func pulseTerminalWindowIfNeeded(windowID: Int) {
        guard (try? windowFocusPulseEnabled()) ?? SettingsKey.defaultWindowFocusPulseEnabled else { return }
        let color = (try? windowFocusPulseColor()) ?? defaultWindowFocusPulseColor()
        terminalFocusPulseController.pulse(windowID: windowID, color: color, yabai: yabai)
    }

    private func terminalAdapterAvailable(_ terminalHost: TerminalHost) -> Bool {
        if terminalHost == .spaces { return true }
        return terminalAdapter(for: terminalHost)?.isAvailable() == true
    }

    private func missingTerminalDependencyMessage(for terminalHost: TerminalHost, operation: String) -> String {
        if terminalHost == .spaces { return "SpacesApp must be running to \(operation) with the built-in terminal." }
        return "\(terminalHost.displayName) is required to \(operation)."
    }

    private func openManagedTerminalWindow(
        terminalHost: TerminalHost, command: String, cwd: String, environment: [String: String] = [:], background: Bool = false
    ) throws -> ManagedTerminalHandle {
        guard let terminalAdapter = terminalAdapter(for: terminalHost) else {
            throw WorkspaceError.invalidArgument(message: "Unsupported terminal host: \(terminalHost.rawValue)")
        }
        let result = try terminalAdapter.openWindowAndRun(command: command, cwd: cwd, environment: environment, background: background)
        return ManagedTerminalHandle(
            fallbackWindowID: result.fallbackWindowID, providerIdentity: result.providerIdentity, hookAttributionID: result.hookAttributionID,
            containerIdentity: result.containerIdentity)
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
        "spaces-\(workspaceID)-\(safeFilename(processName).lowercased())"
    }

    private func shellSingleQuoted(_ raw: String) -> String { "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'" }

    private func tmuxAttachCommand(sessionName: String, cwd: String) -> String {
        "cd \(shellSingleQuoted(cwd)) && exec tmux attach-session -t \(shellSingleQuoted(sessionName))"
    }

    private func startupFailureSummary(from paneOutput: String) -> String? {
        let lines = paneOutput.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        let selectedLines = Array(lines.suffix(3))
        guard !selectedLines.isEmpty else { return nil }

        return selectedLines.map { String($0.prefix(160)) }.joined(separator: "\n")
    }

    private func processStartupFailureMessage(processName: String, commandDescription: String?, exitStatus: Int?, paneOutput: String?) -> String {
        let trimmedProcessName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = commandDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label: String
        if !trimmedProcessName.isEmpty, let trimmedCommand, !trimmedCommand.isEmpty {
            label = "Process '\(trimmedProcessName)' failed to start (\(trimmedCommand))."
        } else if !trimmedProcessName.isEmpty {
            label = "Process '\(trimmedProcessName)' failed to start."
        } else if let trimmedCommand, !trimmedCommand.isEmpty {
            label = "Command failed to start (\(trimmedCommand))."
        } else {
            label = "Process failed to start."
        }

        if let paneOutput, let summary = startupFailureSummary(from: paneOutput) {
            if summary.contains("\n") { return "\(label)\n\(summary)" }
            return "\(label) \(summary)"
        }
        if let exitStatus { return "\(label) Exit status \(exitStatus)." }
        return label
    }

    private func surfacedProcessStartupError(sessionName: String, windowID: String, processName: String, commandDescription: String?)
        -> WorkspaceError
    {
        let paneOutput = try? tmux.capturePane(windowID: windowID)
        let exitStatus = try? tmux.paneExitStatus(windowID: windowID)
        if tmux.hasSession(named: sessionName) { try? tmux.killSession(named: sessionName) }
        return .invalidArgument(
            message: processStartupFailureMessage(
                processName: processName, commandDescription: commandDescription, exitStatus: exitStatus, paneOutput: paneOutput))
    }

    private func verifyProcessSessionStarted(sessionName: String, windowID: String, processName: String, commandDescription: String?) throws {
        let deadline = currentDate().addingTimeInterval(processStartupVerificationTimeout)
        var sawLiveWindow = false
        while currentDate() < deadline {
            if let window = try? tmux.currentWindow(sessionName: sessionName) {
                if (try? tmux.isPaneDead(windowID: window.id)) == true {
                    throw surfacedProcessStartupError(
                        sessionName: sessionName, windowID: window.id, processName: processName, commandDescription: commandDescription)
                }
                sawLiveWindow = true
            } else if !tmux.hasSession(named: sessionName) {
                throw surfacedProcessStartupError(
                    sessionName: sessionName, windowID: windowID, processName: processName, commandDescription: commandDescription)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        if sawLiveWindow { return }
        if !waitForTmuxSession(named: sessionName) {
            throw WorkspaceError.invalidArgument(message: tmuxSessionTimeoutMessage(processName: processName, commandDescription: commandDescription))
        }
    }

    @discardableResult private func attachProcessTmuxSession(
        workspace: WorkspaceRecord, processName: String, commandDescription: String? = nil, terminalHost: TerminalHost, background: Bool = false
    ) throws -> ManagedTerminalHandle {
        let sessionName = processTmuxSessionName(workspaceID: workspace.id, processName: processName)
        let windowInfo = try openManagedTerminalWindow(
            terminalHost: terminalHost, command: tmuxAttachCommand(sessionName: sessionName, cwd: workspace.dir), cwd: workspace.dir,
            background: background)
        guard waitForTmuxSession(named: sessionName) else {
            throw WorkspaceError.invalidArgument(message: tmuxSessionTimeoutMessage(processName: processName, commandDescription: commandDescription))
        }
        return windowInfo
    }

    private func launchProcessInTmux(
        workspace: WorkspaceRecord, processName: String, rawCommand: String, command: String, env: [String: String], terminalHost: TerminalHost,
        background: Bool = false, replaceExistingSession: Bool
    ) throws -> ManagedTerminalHandle {
        let sessionName = processTmuxSessionName(workspaceID: workspace.id, processName: processName)
        if replaceExistingSession, tmux.hasSession(named: sessionName) { try? tmux.killSession(named: sessionName) }
        let runtimeEnv = terminalLaunchEnvironment(base: env, terminalHost: terminalHost)
        _ = try tmux.startSession(
            named: sessionName, windowName: processName, cwd: workspace.dir, env: runtimeEnv,
            command: [terminalLoginShellPath(), "-l", "-c", command])
        guard waitForTmuxSession(named: sessionName) else {
            throw WorkspaceError.invalidArgument(message: tmuxSessionTimeoutMessage(processName: processName, commandDescription: rawCommand))
        }
        if let tmuxWindow = try? currentTmuxWindowInfo(workspaceID: workspace.id, processName: processName) {
            try verifyProcessSessionStarted(
                sessionName: sessionName, windowID: tmuxWindow.id, processName: processName, commandDescription: rawCommand)
        }
        let windowInfo = try attachProcessTmuxSession(
            workspace: workspace, processName: processName, commandDescription: rawCommand, terminalHost: terminalHost, background: background)
        return windowInfo
    }

    private func currentTmuxWindowInfo(workspaceID: String, processName: String) throws -> TmuxWindowInfo? {
        try tmux.currentWindow(sessionName: processTmuxSessionName(workspaceID: workspaceID, processName: processName))
    }

    private func interactiveShellCommand(cwd _: String) -> String { "exec \(shellSingleQuoted(terminalLoginShellPath())) -l" }

    private func terminalLaunchEnvironment(base: [String: String], terminalHost: TerminalHost, includeInheritedPath: Bool = true) -> [String: String]
    {
        var env = base
        if includeInheritedPath, let path = Shell.currentProcessEnvironment()["PATH"], !path.isEmpty { env["PATH"] = path }
        for key in [DatabaseLocator.databasePathEnvironmentVariable, "SPACES_RUNTIME_DIR", "SPACES_E2E_EVENTS_LOG", "DEBUG"] {
            if let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                env[key] = value
            }
        }
        env["SPACES_TERMINAL_HOST"] = terminalHost.rawValue
        env[Self.terminalTrackingIDEnvVar] = env[Self.terminalTrackingIDEnvVar] ?? UUID().uuidString
        return env
    }

    private func commandPrefixedWithShellEnvironment(_ command: String, env: [String: String]) -> String {
        guard !env.isEmpty else { return command }
        let exports = env.sorted(by: { $0.key < $1.key }).map { "export \($0.key)=\(shellQuoted($0.value))" }.joined(separator: "; ")
        return "\(exports); \(command)"
    }

    private func terminalShellPathOverride() -> String? { terminalLoginShellPath() }

    private func terminalLoginShellPath() -> String {
        let shellPath = Shell.resolvedLoginShellExecutablePath(environment: Shell.currentProcessEnvironment())?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return shellPath.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    private enum BuiltInTerminalReadinessPolicy: String {
        case sessionReady = "session_ready"
        case stableChildPID = "stable_child_pid"
    }

    private func launchSpacesTerminalSession(
        title: String, workingDirectory: String, command: String?, showMode: TerminalAttachmentMode,
        backend: TerminalSessionBackendKind = .ghosttyEmbedded, readinessPolicy: BuiltInTerminalReadinessPolicy = .stableChildPID,
        sessionID: String? = nil, lifetimePolicy: TerminalSessionLifetimePolicy = .persistent, workspaceID: String? = nil,
        kind: TerminalSessionKind = .shell
    ) throws -> SpacesTerminalSessionHandle {
        let sessionID = sessionID ?? UUID().uuidString
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: backend, lifetimePolicy: lifetimePolicy, title: title, workingDirectory: workingDirectory,
            shell: terminalShellPathOverride() ?? "/bin/zsh", command: command, createdAt: nowISO8601(), workspaceID: workspaceID, kind: kind)

        let snapshot = bestEffortYabaiWindowSnapshot()
        builtInTerminalWindowOpener(sessionID, showMode)
        let waitStartedAt = currentDate()
        let sessionSummary: TerminalServiceSessionSummary
        do {
            sessionSummary = try builtInTerminalSessionLauncher(launchConfiguration)
            logTerminalPerfMetric(
                "terminal_session_wait_ready", target: "session=\(sessionID)",
                detail:
                    "policy=\(readinessPolicy.rawValue) state=\(sessionSummary.state.rawValue) child_pid=\(sessionSummary.childPID.map(String.init) ?? "-")",
                elapsedMS: elapsedMS(since: waitStartedAt), success: true)
        } catch {
            logTerminalPerfMetric(
                "terminal_session_wait_ready", target: "session=\(sessionID)", detail: "policy=\(readinessPolicy.rawValue)",
                elapsedMS: elapsedMS(since: waitStartedAt), success: false)
            builtInTerminalWindowCloser(sessionID)
            throw error
        }
        let windowCaptureDeadline = Date().addingTimeInterval(2)
        var windowID = bestEffortCaptureNewAppWindowID(snapshot: snapshot, appName: TerminalHost.spaces.appName)
        while windowID == nil, Date() < windowCaptureDeadline {
            Thread.sleep(forTimeInterval: 0.05)
            windowID = bestEffortCaptureNewAppWindowID(snapshot: snapshot, appName: TerminalHost.spaces.appName)
        }
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        let refreshedRuntimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        return SpacesTerminalSessionHandle(
            sessionID: sessionID, childPID: (refreshedRuntimeState?.childPID ?? sessionSummary.childPID).map(Int.init), windowID: windowID,
            outputPath: sessionSummary.outputPath)
    }

    private func shellQuoted(_ token: String) -> String {
        guard !token.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/:")
        if token.unicodeScalars.allSatisfy({ safe.contains($0) }) { return token }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func processLaunchCommand(template: ProcessTemplate) throws -> String {
        let trimmed = template.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceError.invalidArgument(message: "Process command is required.") }
        return trimmed
    }

    private func spacesTerminalCommand(template: ProcessTemplate, env: [String: String]) throws -> String {
        let command = try processLaunchCommand(template: template)
        let runtimeEnv = terminalLaunchEnvironment(base: env, terminalHost: .spaces)
        let shellPath = terminalLoginShellPath()
        return commandPrefixedWithShellEnvironment("exec \(shellQuoted(shellPath)) -l -c \(shellQuoted(command))", env: runtimeEnv)
    }

    public func validateProcessTemplate(_ template: ProcessTemplate) throws { _ = try processLaunchCommand(template: template) }

    public func validateProcessTemplates(_ templates: [ProcessTemplate]) throws {
        for template in templates { try validateProcessTemplate(template) }
    }

    private func configuredProcessTemplate(for process: RunningProcessRecord, workspace: WorkspaceRecord, project: ProjectRecord) throws
        -> ProcessTemplate
    {
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        if let templateID = process.templateID?.trimmingCharacters(in: .whitespacesAndNewlines), !templateID.isEmpty,
            let template = settings?.processes.first(where: { $0.id == templateID })
        {
            return template
        }
        let processKey = process.templateName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let template = settings?.processes.first(where: { self.processKey(for: $0) == processKey }) { return template }
        return ProcessTemplate(name: process.templateName, command: process.command)
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
        guard
            let matchedSession = resolvedSessions.compactMap({ resolved -> (session: ResolvedBrowserSession, score: Int)? in
                guard let score = browserURLMatchScore(targetURL, targetURL: resolved.prefix) else { return nil }
                return (resolved, score)
            }).max(by: { lhs, rhs in
                if lhs.score == rhs.score { return lhs.session.prefix.count < rhs.session.prefix.count }
                return lhs.score < rhs.score
            })?.session, let extractedWindow = sessions[matchedSession.index].extractedWindow, extractedWindow.isValid
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

    private func focusScannedBrowserTab(workspaceID: String, targetURL: String) throws -> Bool {
        let focusStartedAt = currentDate()
        for attempt in 1...2 {
            guard let target = try scannedBrowserFocusTarget(workspaceID: workspaceID, targetURL: targetURL, forceRefresh: attempt == 2),
                let cachedTarget = cachedScannedBrowserTabTarget(workspaceID: workspaceID, windowID: target.windowID, targetURL: target.matchedURL)
            else {
                logBrowserFocus("workspace=\(workspaceID) indexed_miss target=\(targetURL) attempt=\(attempt)")
                continue
            }

            let focusByIndexStartedAt = currentDate()
            let focused = try chrome.focusTab(windowID: target.windowID, tabIndex: target.tabIndex)
            logBrowserFocus(
                "workspace=\(workspaceID) indexed_focus window=\(target.windowID) tab_index=\(target.tabIndex) attempt=\(attempt) success=\(focused ? "1" : "0") focus_ms=\(elapsedMS(since: focusByIndexStartedAt))"
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
                    "workspace=\(workspaceID) indexed_verify window=\(target.windowID) tab_index=\(target.tabIndex) attempt=\(attempt) exact_match=\(matchesTarget ? "1" : "0") workspace_match=\(matchesWorkspace ? "1" : "0") verify_ms=\(elapsedMS(since: verifyStartedAt)) url=\(activeURL ?? "")"
                )
                if matchesTarget {
                    logBrowserFocus(
                        "workspace=\(workspaceID) indexed_done window=\(target.windowID) target=\(targetURL) refreshed=\(attempt == 2 ? "1" : "0") elapsed_ms=\(elapsedMS(since: focusStartedAt))"
                    )
                    return true
                }
            }
        }
        logBrowserFocus("workspace=\(workspaceID) indexed_failed target=\(targetURL) elapsed_ms=\(elapsedMS(since: focusStartedAt))")
        return false
    }

    private func scannedBrowserFocusTarget(workspaceID: String, targetURL: String, forceRefresh: Bool = false) throws -> ScannedBrowserFocusTarget? {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let browserPrefixes = try resolvedBrowserSessionPrefixes(project: project, workspace: workspace)
        guard !browserPrefixes.isEmpty else { return nil }
        let windows = try liveBrowserWindows(workspaceID: workspaceID, browserPrefixes: browserPrefixes, forceRefresh: forceRefresh)
        let matchedWindow = windows.compactMap { window -> (window: WindowRecord, score: Int)? in
            guard let scannedURL = window.targetURL, let score = browserURLMatchScore(scannedURL, targetURL: targetURL) else { return nil }
            return (window, score)
        }.max(by: { lhs, rhs in
            if lhs.score == rhs.score { return lhs.window.orderIndex > rhs.window.orderIndex }
            return lhs.score < rhs.score
        })?.window
        guard let matchedWindow, let matchedURL = matchedWindow.targetURL, let chromeWindowID = matchedWindow.windowID else { return nil }
        guard let cachedTarget = cachedScannedBrowserTabTarget(workspaceID: workspaceID, windowID: chromeWindowID, targetURL: matchedURL) else {
            return nil
        }
        return ScannedBrowserFocusTarget(windowID: chromeWindowID, tabIndex: cachedTarget.tabIndex, matchedURL: matchedURL)
    }

    private func cachedScannedBrowserTabTarget(workspaceID: String, windowID: Int, targetURL: String) -> CachedScannedBrowserTabTarget? {
        browserScanCacheLock.lock()
        defer { browserScanCacheLock.unlock() }
        guard let entry = browserWindowScanCacheByWorkspace[workspaceID] else { return nil }
        let key = "\(windowID):\(targetURL)"
        guard let tabIndex = entry.scanResult.tabIndexByWindowAndURL[key] else { return nil }
        return CachedScannedBrowserTabTarget(tabIndex: tabIndex, browserPrefixes: entry.browserPrefixes)
    }

    private func browserURLMatchesWorkspace(_ url: String, browserPrefixes: [String]) -> Bool {
        browserPrefixes.contains(where: { browserURLMatchesTarget(url, targetURL: $0) })
    }

    private func browserURLMatchesTarget(_ url: String, targetURL: String) -> Bool { browserURLMatchScore(url, targetURL: targetURL) != nil }

    private struct ComparableBrowserURL {
        let scheme: String
        let host: String
        let port: Int?
        let path: String
    }

    private func comparableBrowserURL(_ raw: String) -> ComparableBrowserURL? {
        guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(), var host = components.host?.lowercased()
        else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return ComparableBrowserURL(scheme: scheme, host: host, port: components.port, path: path)
    }

    private func browserURLMatchScore(_ url: String, targetURL: String) -> Int? {
        if url == targetURL { return 3_000_000 + targetURL.count }
        if url.hasPrefix(targetURL) { return 2_000_000 + targetURL.count }
        guard let actual = comparableBrowserURL(url), let target = comparableBrowserURL(targetURL) else { return nil }
        guard actual.scheme == target.scheme, actual.host == target.host, actual.port == target.port else { return nil }
        if target.path == "/" { return 1_000_000 }
        if actual.path == target.path { return 1_500_000 + target.path.count }
        if actual.path.hasPrefix(target.path + "/") { return 1_000_000 + target.path.count }
        return nil
    }

    private func elapsedMS(since startedAt: Date) -> Int { Int(currentDate().timeIntervalSince(startedAt) * 1000) }

    private func logCycleProfile(_ message: String) {
        guard debugLoggingEnabled() else { return }
        fputs("spaces: cycle \(message)\n", stderr)
    }

    private func logBrowserFocus(_ message: String) {
        guard debugLoggingEnabled() else { return }
        fputs("spaces: browser focus \(message)\n", stderr)
    }

    private func logPerfMetric(_ metric: String, workspaceID: String, target: String, detail: String = "", elapsedMS: Int, success: Bool) {
        // Manual real-system E2E parses these `spaces: perf metric=...` lines for
        // focus/cycle timing summaries. Treat the prefix and key/value shape as a
        // compatibility surface for the shell harness when changing debug logs.
        TerminalPerformance.logWorkspaceMetric(
            metric, workspaceID: workspaceID, target: target, elapsedMS: elapsedMS, success: success, detail: detail)
    }

    private func logTerminalPerfMetric(_ metric: String, target: String, detail: String = "", elapsedMS: Int, success: Bool) {
        TerminalPerformance.logMetric(metric, target: target, elapsedMS: elapsedMS, success: success, detail: detail)
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
            let matchScore: Int
        }
        var matchedTabs: [MatchedTab] = []
        var seen = Set<String>()
        for tab in tabs {
            guard
                let matchedPrefix = browserPrefixes.enumerated().compactMap({ index, prefix -> (index: Int, score: Int)? in
                    guard let score = browserURLMatchScore(tab.url, targetURL: prefix) else { return nil }
                    return (index, score)
                }).max(by: { lhs, rhs in
                    if lhs.score == rhs.score { return lhs.index > rhs.index }
                    return lhs.score < rhs.score
                })
            else { continue }
            let key = "\(tab.windowID):\(tab.url)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            matchedTabs.append(MatchedTab(tab: tab, prefixIndex: matchedPrefix.index, matchScore: matchedPrefix.score))
        }
        matchedTabs.sort { lhs, rhs in
            if lhs.prefixIndex != rhs.prefixIndex { return lhs.prefixIndex < rhs.prefixIndex }
            if lhs.matchScore != rhs.matchScore { return lhs.matchScore > rhs.matchScore }
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
            fputs(
                "spaces: browser scan workspace=\(workspaceID) tabs=\(tabs.count) matches=\(browserWindows.count) elapsed_ms=\(elapsedMS)\n", stderr)
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

    public func guiCommandPaletteHotkey() throws -> String {
        try store.setting(key: SettingsKey.guiCommandPaletteHotkey) ?? SettingsKey.defaultGUICommandPaletteHotkey
    }

    public func setGUICommandPaletteHotkey(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiCommandPaletteHotkey, value: raw) }

    public func guiLeaderHotkey() throws -> String { HotkeySpec.normalizedModifierSet(try guiLeaderModifiers()) }

    public func setGUILeaderHotkey(_ raw: String?) throws { try store.setSetting(key: SettingsKey.guiLeaderHotkey, value: raw) }

    public func guiAlertsShortcut() throws -> String {
        try effectiveLeaderBackedShortcut(settingKey: SettingsKey.guiAlertsShortcut, defaultValue: SettingsKey.defaultGUIAlertsShortcut)
    }

    public func setGUIAlertsShortcut(_ raw: String?) throws {
        try store.setSetting(key: SettingsKey.guiAlertsShortcut, value: try normalizeLeaderBackedShortcut(raw))
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
        try effectiveLeaderBackedShortcut(settingKey: SettingsKey.guiOpenTerminalShortcut, defaultValue: SettingsKey.defaultGUIOpenTerminalShortcut)
    }

    public func setGUIOpenTerminalShortcut(_ raw: String?) throws {
        try store.setSetting(key: SettingsKey.guiOpenTerminalShortcut, value: try normalizeLeaderBackedShortcut(raw))
    }

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

    public func alertsDismissedAttentionItemIDs() throws -> Set<String> {
        guard let raw = try store.setting(key: SettingsKey.alertsDismissedAttentionItems), !raw.isEmpty else { return [] }
        guard let data = raw.data(using: .utf8) else { return [] }
        let decoded = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return Set(decoded)
    }

    public func setAlertsDismissedAttentionItemIDs(_ ids: Set<String>) throws {
        guard !ids.isEmpty else {
            try store.setSetting(key: SettingsKey.alertsDismissedAttentionItems, value: nil)
            return
        }
        let encoded = try JSONEncoder().encode(ids.sorted())
        try store.setSetting(key: SettingsKey.alertsDismissedAttentionItems, value: String(decoding: encoded, as: UTF8.self))
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

    public func activeWorkspaceID() throws -> String? { try store.setting(key: "active_workspace_id") }

    public func setActiveWorkspace(id: String?) throws { try store.setSetting(key: "active_workspace_id", value: id) }

    private func normalizeDir(id: String, _ dir: String) throws -> ProjectRecord {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceError.invalidArgument(message: "Project directory not found: \(dir)")
        }
        let isGit = git.isRepo(path: dir)
        let branch = isGit ? git.defaultBranch(path: dir) : nil
        let name = URL(fileURLWithPath: dir).lastPathComponent
        return ProjectRecord(id: id, name: name, dir: dir, isGitRepo: isGit, defaultBranch: branch)
    }

    private func configuredProjectRecord(baseRecord: ProjectRecord, update: (inout ProjectRecord) -> Void) throws -> ProjectRecord {
        var record = baseRecord
        update(&record)
        let previousPorts = baseRecord.ports
        let previousProcesses = baseRecord.processes
        let previousAgentLaunchers = baseRecord.agentLaunchers
        record = ProjectRecord(
            id: baseRecord.id, name: baseRecord.name, dir: baseRecord.dir, isGitRepo: baseRecord.isGitRepo, defaultBranch: baseRecord.defaultBranch,
            isCollapsed: baseRecord.isCollapsed, setupScript: record.setupScript, stopScript: record.stopScript, ports: record.ports,
            processes: record.processes, browserSessions: record.browserSessions, agentLaunchers: record.agentLaunchers)
        record.ports = normalizePortDefinitionIDs(previous: previousPorts, updated: record.ports)
        record.processes = normalizeProcessTemplateIDs(previous: previousProcesses, updated: record.processes)
        record.agentLaunchers = normalizeAgentLauncherIDs(previous: previousAgentLaunchers, updated: record.agentLaunchers)
        record.ports = try normalizedPortDefinitions(record.ports)
        try validateProcessTemplates(record.processes)
        try validateUniqueConfiguredFocusNames(
            processes: record.processes, browserSessions: record.browserSessions, agentLaunchers: record.agentLaunchers)
        return record
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

        let workspace = try createImportedGitDefaultWorkspaceOnDisk(project: project, branch: branch)
        try store.upsert(workspace: workspace)
        try seedWorkspaceSettings(project: project, workspace: workspace)
        let appConfig = try store.appConfig()
        let portDefinitions = try store.workspacePortDefinitions(workspaceID: workspace.id)
        _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, definitions: portDefinitions, range: appConfig.portRange)
    }

    private func resolveWorkspace(id: String) throws -> (ProjectRecord, WorkspaceRecord) {
        guard let workspace = try store.workspace(id: id) else { throw WorkspaceError.invalidArgument(message: "Workspace not found.") }
        guard let project = try store.project(id: workspace.projectID) else { throw WorkspaceError.missingProject(dir: workspace.projectID) }
        return (project, workspace)
    }

    private func ensureWorkspaceSettings(for project: ProjectRecord) throws {
        let workspaces = try store.workspaces(projectID: project.id, includeArchived: true)
        for workspace in workspaces {
            let hasSettings = try store.workspaceSettingsExists(workspaceID: workspace.id)
            if !hasSettings { try seedWorkspaceSettings(project: project, workspace: workspace) }
        }
    }

    private func createImportedGitDefaultWorkspaceOnDisk(project: ProjectRecord, branch: String) throws -> WorkspaceRecord {
        let worktreeRoot = try worktreeRoot(project: project)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let workspaceDir = worktreeRoot.appendingPathComponent(branch, isDirectory: true).path
        try git.createWorktree(path: project.dir, worktreePath: workspaceDir, branch: branch, targetBranch: branch)
        return WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, title: branch, dir: workspaceDir, dirname: branch, branch: branch, targetBranch: branch,
            isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil)
    }

    private func spacesYAMLConfigURL(project: ProjectRecord) throws -> URL {
        let directory: String
        if let defaultWorkspace = try defaultWorkspace(projectID: project.id) {
            directory = defaultWorkspace.dir
        } else if project.isGitRepo {
            throw WorkspaceError.invalidArgument(message: "Default workspace not found for project \(project.name).")
        } else {
            directory = project.dir
        }
        return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(SpacesYAMLService.fileName)
    }

    private func spacesYAMLDocumentIfPresent(in directory: URL) throws -> SpacesYAMLDocument? {
        let url = directory.appendingPathComponent(SpacesYAMLService.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try SpacesYAMLService.load(from: url)
    }

    private func applyProjectTemplateToAllWorkspaces(project: ProjectRecord) throws {
        let workspaces = try store.workspaces(projectID: project.id, includeArchived: true)
        for workspace in workspaces { try applyProjectTemplate(project, to: workspace, syncPorts: !workspace.isArchived) }
    }

    private func workspaceConfigurationSnapshots(projectID: String) throws -> [WorkspaceConfigurationSnapshot] {
        let workspaces = try store.workspaces(projectID: projectID, includeArchived: true)
        return try workspaces.map { workspace in
            let settings: WorkspaceSettings?
            if try store.workspaceSettingsExists(workspaceID: workspace.id) {
                settings = WorkspaceSettings(
                    stopScript: try store.workspaceStopScript(workspaceID: workspace.id),
                    ports: try store.workspacePortDefinitions(workspaceID: workspace.id),
                    processes: try store.workspaceProcesses(workspaceID: workspace.id),
                    browserSessions: try store.workspaceBrowserSessions(workspaceID: workspace.id),
                    agentLaunchers: try store.workspaceAgentLaunchers(workspaceID: workspace.id))
            } else {
                settings = nil
            }
            return WorkspaceConfigurationSnapshot(
                workspace: workspace, settings: settings, assignedPorts: try store.workspacePortsAssigned(workspaceID: workspace.id))
        }
    }

    private func restoreSpacesYAMLImportSnapshot(project: ProjectRecord, workspaces: [WorkspaceConfigurationSnapshot]) throws {
        try store.upsert(project: project)
        for snapshot in workspaces { try restoreWorkspaceConfiguration(snapshot) }
    }

    private func restoreWorkspaceConfiguration(_ snapshot: WorkspaceConfigurationSnapshot) throws {
        try PortAllocator(store: store).releasePorts(workspaceID: snapshot.workspace.id)
        guard let settings = snapshot.settings else {
            try store.deleteWorkspaceConfiguration(workspaceID: snapshot.workspace.id)
            return
        }

        try store.setWorkspaceStopScript(workspaceID: snapshot.workspace.id, stopScript: settings.stopScript)
        try store.setWorkspacePortDefinitions(workspaceID: snapshot.workspace.id, definitions: settings.ports)
        try store.setWorkspaceProcesses(workspaceID: snapshot.workspace.id, processes: settings.processes)
        try store.setWorkspaceBrowserSessions(workspaceID: snapshot.workspace.id, sessions: settings.browserSessions)
        try store.setWorkspaceAgentLaunchers(workspaceID: snapshot.workspace.id, launchers: settings.agentLaunchers)
        try store.touchWorkspaceSettings(workspaceID: snapshot.workspace.id, updatedAt: nowISO8601())
        try store.setWorkspacePorts(
            workspaceID: snapshot.workspace.id, ports: snapshot.assignedPorts.map { $0.port }, names: snapshot.assignedPorts.map { $0.name },
            definitionIDs: snapshot.assignedPorts.map { $0.definitionID })
        if !snapshot.workspace.isArchived, !snapshot.assignedPorts.isEmpty {
            PortReserver.shared.reservePorts(workspaceID: snapshot.workspace.id, ports: snapshot.assignedPorts.map { $0.port })
        }
    }

    private func applyProjectTemplate(_ project: ProjectRecord, to workspace: WorkspaceRecord, syncPorts: Bool) throws {
        guard var settings = try loadWorkspaceSettings(project: project, workspace: workspace) else {
            throw WorkspaceError.missingProject(dir: project.dir)
        }
        let previousPorts = settings.ports
        let previousProcesses = settings.processes
        let previousAgentLaunchers = settings.agentLaunchers
        settings.stopScript = project.stopScript
        settings.ports = project.ports
        settings.processes = seededWorkspaceProcesses(from: project.processes)
        settings.browserSessions = project.browserSessions
        settings.agentLaunchers = project.agentLaunchers
        settings.ports = normalizePortDefinitionIDs(previous: previousPorts, updated: settings.ports)
        settings.ports = try normalizedPortDefinitions(settings.ports)
        settings.processes = normalizeProcessTemplateIDs(previous: previousProcesses, updated: settings.processes)
        settings.agentLaunchers = normalizeAgentLauncherIDs(previous: previousAgentLaunchers, updated: settings.agentLaunchers)
        try validateProcessTemplates(settings.processes)
        try validateWorkspaceFocusNames(
            workspaceID: workspace.id, processes: settings.processes, browserSessions: settings.browserSessions,
            agentLaunchers: settings.agentLaunchers, agentWindows: try store.agentWindows(workspaceID: workspace.id))
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: settings.stopScript)
        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: settings.ports)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: settings.processes)
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: settings.browserSessions)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: settings.agentLaunchers)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: nowISO8601())
        if syncPorts {
            let appConfig = try store.appConfig()
            _ = try PortAllocator(store: store).syncPorts(workspaceID: workspace.id, definitions: settings.ports, range: appConfig.portRange)
        }
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

    private func normalizedPortDefinitions(_ definitions: [PortDefinition]) throws -> [PortDefinition] {
        try definitions.map { definition in
            let trimmedName = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { throw WorkspaceError.invalidArgument(message: "Port name is required.") }
            return PortDefinition(id: definition.id, name: trimmedName)
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

    private func normalizeAgentLauncherIDs(previous: [AgentLauncher], updated: [AgentLauncher]) -> [AgentLauncher] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let previousNames = previous.map { normalizedFocusName($0.name) }
        let previousCommands = previous.map { $0.command.trimmingCharacters(in: .whitespacesAndNewlines) }
        let nameCounts = Dictionary(previousNames.map { ($0, 1) }, uniquingKeysWith: +)
        let commandCounts = Dictionary(previousCommands.map { ($0, 1) }, uniquingKeysWith: +)
        var usedIDs = Set<String>()

        return updated.map { launcher in
            if previousByID[launcher.id] != nil {
                usedIDs.insert(launcher.id)
                return launcher
            }

            let normalizedName = normalizedFocusName(launcher.name)
            if nameCounts[normalizedName] == 1,
                let match = previous.first(where: { normalizedFocusName($0.name) == normalizedName && !usedIDs.contains($0.id) })
            {
                usedIDs.insert(match.id)
                return AgentLauncher(id: match.id, name: launcher.name, command: launcher.command)
            }

            let trimmedCommand = launcher.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if commandCounts[trimmedCommand] == 1,
                let match = previous.first(where: {
                    $0.command.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedCommand && !usedIDs.contains($0.id)
                })
            {
                usedIDs.insert(match.id)
                return AgentLauncher(id: match.id, name: launcher.name, command: launcher.command)
            }

            return launcher
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
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: seededWorkspaceProcesses(from: project.processes))
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: project.browserSessions)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: project.agentLaunchers)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: nowISO8601())
    }

    private func seededWorkspaceProcesses(from templates: [ProcessTemplate]) -> [ProcessTemplate] {
        templates.map { template in
            ProcessTemplate(id: UUID().uuidString, name: template.name, command: template.command, kind: template.kind, onExit: template.onExit)
        }
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

    private func workspaceSetupLogPath(workspaceID: String) throws -> String {
        let workspaceSetupDirectory = URL(fileURLWithPath: try runtimeDirectory(), isDirectory: true).appendingPathComponent(
            "workspace-setup", isDirectory: true
        ).appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceSetupDirectory, withIntermediateDirectories: true)
        return workspaceSetupDirectory.appendingPathComponent("setup.log", isDirectory: false).path
    }

    private func prepareWorkspaceSetupLog(workspaceID: String) throws -> String {
        let path = try workspaceSetupLogPath(workspaceID: workspaceID)
        _ = FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 0)
        try handle.close()
        return path
    }

    private func runWorkspaceSetupScript(_ script: String, cwd: String, logPath: String) throws -> WorkspaceSetupRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", script]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        process.environment = Shell.currentProcessEnvironment()

        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        defer { try? logHandle.close() }
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()

        process.waitUntilExit()
        try? logHandle.synchronize()
        return WorkspaceSetupRunResult(exitCode: Int(process.terminationStatus), logPath: logPath)
    }

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
        let logPath = try prepareWorkspaceSetupLog(workspaceID: workspace.id)
        try store.setWorkspaceSetupState(
            workspaceID: workspace.id, status: .running, errorMessage: nil, startedAt: startedAt, finishedAt: nil, exitCode: nil, logPath: logPath)
        guard let setupScript, !setupScript.isEmpty else {
            try store.setWorkspaceSetupState(
                workspaceID: workspace.id, status: .succeeded, errorMessage: nil, startedAt: startedAt, finishedAt: nowISO8601(), exitCode: 0,
                logPath: logPath)
            return
        }
        let result: WorkspaceSetupRunResult
        do {
            let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
            let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
            result = try runWorkspaceSetupScript(applyEnvVars(setupScript, env: env), cwd: workspace.dir, logPath: logPath)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try store.setWorkspaceSetupState(
                workspaceID: workspace.id, status: .failed, errorMessage: message, startedAt: startedAt, finishedAt: nowISO8601(), exitCode: nil,
                logPath: logPath)
            throw error
        }
        guard result.exitCode == 0 else {
            let message = "Setup script exited with code \(result.exitCode)."
            try store.setWorkspaceSetupState(
                workspaceID: workspace.id, status: .failed, errorMessage: message, startedAt: startedAt, finishedAt: nowISO8601(),
                exitCode: result.exitCode, logPath: result.logPath)
            throw WorkspaceError.invalidArgument(message: "\(message) See log: \(result.logPath)")
        }
        try store.setWorkspaceSetupState(
            workspaceID: workspace.id, status: .succeeded, errorMessage: nil, startedAt: startedAt, finishedAt: nowISO8601(),
            exitCode: result.exitCode, logPath: result.logPath)
    }

    private func waitForWorkspaceSetupToComplete(workspaceID: String) throws {
        let waitStartedAt = currentDate()
        while true {
            let setupState = try workspaceSetupState(workspaceID: workspaceID)
            switch setupState.status {
            case .succeeded: return
            case .failed:
                let detail = workspaceSetupFailureDetail(setupState)
                throw WorkspaceError.invalidArgument(message: "Workspace setup failed: \(detail)")
            case .pending, .running:
                if currentDate().timeIntervalSince(waitStartedAt) > 900 {
                    throw WorkspaceError.invalidArgument(
                        message: "Timed out waiting for workspace setup to finish. Retry launch after setup completes or run `spaces restart`.")
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    private func requireWorkspaceSetupSucceeded(workspaceID: String) throws {
        let setupState = try workspaceSetupState(workspaceID: workspaceID)
        guard setupState.status == .succeeded else { throw WorkspaceError.invalidArgument(message: workspaceSetupBlockedMessage(setupState)) }
    }

    private func workspaceSetupBlockedMessage(_ state: WorkspaceSetupState) -> String {
        switch state.status {
        case .succeeded: return "Workspace setup has completed."
        case .pending: return "Workspace setup has not run. Run setup before launching workspace runtime."
        case .running: return "Workspace setup is still running. Wait for setup to finish before launching workspace runtime."
        case .failed: return "Workspace setup failed: \(workspaceSetupFailureDetail(state))"
        }
    }

    private func workspaceSetupFailureDetail(_ state: WorkspaceSetupState) -> String {
        var parts: [String] = []
        if let message = state.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty { parts.append(message) }
        if let exitCode = state.exitCode { parts.append("exit code \(exitCode)") }
        if let logPath = state.logPath?.trimmingCharacters(in: .whitespacesAndNewlines), !logPath.isEmpty { parts.append("log: \(logPath)") }
        return parts.isEmpty ? "unknown setup error" : parts.joined(separator: ", ")
    }

    private func withWorkspaceSetupLock<T>(workspaceID: String, operation: () throws -> T) throws -> T {
        workspaceSetupLock.lock()
        if workspaceSetupInFlight.contains(workspaceID) {
            workspaceSetupLock.unlock()
            throw WorkspaceError.invalidArgument(message: "Workspace setup is already in progress.")
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
            let key = namedPort.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            env[key] = String(namedPort.port)
        }
        env["SPACES_WORKSPACE_DIR"] = workspace.dir
        env["SPACES_PROJECT_DIR"] = project.dir
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
        let restartRequiringEdits = edits.filter(\.commandChanged)
        if !restartRequiringEdits.isEmpty, !restartChangedCommands {
            throw WorkspaceError.invalidArgument(message: "Changing a running process command requires restart confirmation.")
        }

        let runningProcesses = try store.runningProcesses(workspaceID: workspace.id)
        let runningByKey = Dictionary(uniqueKeysWithValues: runningProcesses.map { ($0.templateName, $0) })

        if !restartRequiringEdits.isEmpty {
            for edit in restartRequiringEdits {
                guard let runningProcess = runningByKey[edit.previousKey] else { continue }
                try validateRunningProcessRestart(project: project, workspace: workspace, process: runningProcess, updatedTemplate: edit.updated)
            }
        }

        for edit in edits {
            guard let runningProcess = runningByKey[edit.previousKey] else { continue }
            if edit.commandChanged {
                let restartedProcess = RunningProcessRecord(
                    id: runningProcess.id, workspaceID: runningProcess.workspaceID, templateID: edit.updated.id, templateName: edit.updatedKey,
                    command: edit.updated.command, runtimeTargetID: runningProcess.runtimeTargetID, terminalApp: runningProcess.terminalApp,
                    windowID: runningProcess.windowID, terminalTrackingID: runningProcess.terminalTrackingID,
                    terminalNativeID: runningProcess.terminalNativeID, terminalContainerID: runningProcess.terminalContainerID,
                    pid: runningProcess.pid, status: runningProcess.status, logPath: runningProcess.logPath,
                    lastOutputAt: runningProcess.lastOutputAt, startedAt: runningProcess.startedAt, exitedAt: runningProcess.exitedAt)
                try restartProcessInTerminal(workspaceID: workspace.id, process: restartedProcess, templateOverride: edit.updated)
            } else if edit.keyChanged {
                try relabelRunningProcess(
                    workspaceID: workspace.id, process: runningProcess, templateID: edit.updated.id, templateName: edit.updatedKey,
                    command: runningProcess.command)
            }
        }
    }

    private func validateRunningProcessRestart(
        project: ProjectRecord, workspace: WorkspaceRecord, process: RunningProcessRecord, updatedTemplate: ProcessTemplate
    ) throws {
        let terminalHost = try configuredTerminalHost()
        guard terminalAdapterAvailable(terminalHost) else {
            throw WorkspaceError.dependencyMissing(message: missingTerminalDependencyMessage(for: terminalHost, operation: "launch processes"))
        }
        try validateProcessTemplate(updatedTemplate)
    }

    private func relabelRunningProcess(
        workspaceID: String, process: RunningProcessRecord, templateID: String? = nil, templateName: String, command: String
    ) throws {
        let updatedProcess = RunningProcessRecord(
            id: process.id, workspaceID: process.workspaceID, templateID: templateID ?? process.templateID, templateName: templateName,
            command: command, runtimeTargetID: process.runtimeTargetID, terminalApp: process.terminalApp, windowID: process.windowID,
            terminalTrackingID: process.terminalTrackingID, terminalNativeID: process.terminalNativeID,
            terminalContainerID: process.terminalContainerID, pid: process.pid, status: process.status, logPath: process.logPath,
            lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: process.exitedAt)
        try store.upsert(runningProcess: updatedProcess)
        if let terminalWindow = try store.windows(workspaceID: workspaceID).first(where: {
            $0.role == "terminal" && matchesTrackedTerminalWindow($0, process: process)
        }) {
            try store.upsert(
                window: WindowRecord(
                    id: terminalWindow.id, workspaceID: terminalWindow.workspaceID, app: terminalWindow.app, name: templateName, detail: command,
                    targetURL: terminalWindow.targetURL, windowID: terminalWindow.windowID, terminalTrackingID: terminalWindow.terminalTrackingID,
                    terminalNativeID: terminalWindow.terminalNativeID, terminalContainerID: terminalWindow.terminalContainerID,
                    role: terminalWindow.role, orderIndex: terminalWindow.orderIndex, lastSeenAt: nowISO8601()))
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

        for process in toStop {
            if let pid = resolvedRuntimePID(for: process) { terminateProcessGroup(pid: pid) }
            if isManagedTerminalApp(process.terminalApp) { terminateBuiltInTerminalSession(for: process) }
            try store.deleteRunningProcess(id: process.id)
            if let terminalWindow = try store.windows(workspaceID: workspace.id).first(where: { matchesTrackedTerminalWindow($0, process: process) })
            {
                try store.deleteWindow(id: terminalWindow.id)
            }
        }

        for (desired, process) in toRelabel {
            let updated = RunningProcessRecord(
                id: process.id, workspaceID: workspace.id, templateID: desired.template.id, templateName: desired.desiredKey,
                command: process.command, runtimeTargetID: process.runtimeTargetID, terminalApp: process.terminalApp, windowID: process.windowID,
                terminalTrackingID: process.terminalTrackingID, terminalNativeID: process.terminalNativeID,
                terminalContainerID: process.terminalContainerID, pid: process.pid, status: process.status, logPath: process.logPath,
                lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: process.exitedAt)
            try store.upsert(runningProcess: updated)
            if let terminalWindow = try store.windows(workspaceID: workspace.id).first(where: {
                $0.role == "terminal" && matchesTrackedTerminalWindow($0, process: process)
            }) {
                try store.upsert(
                    window: WindowRecord(
                        id: terminalWindow.id, workspaceID: terminalWindow.workspaceID, app: terminalWindow.app, name: desired.desiredKey,
                        detail: updated.command, targetURL: terminalWindow.targetURL, windowID: terminalWindow.windowID,
                        terminalTrackingID: terminalWindow.terminalTrackingID, terminalNativeID: terminalWindow.terminalNativeID,
                        terminalContainerID: terminalWindow.terminalContainerID, role: terminalWindow.role, orderIndex: terminalWindow.orderIndex,
                        lastSeenAt: nowISO8601()))
            }
        }

        for (desired, process) in toRestart {
            let name = desired.desiredKey
            let updatedProcess = RunningProcessRecord(
                id: process.id, workspaceID: process.workspaceID, templateID: desired.template.id, templateName: name,
                command: desired.template.command, runtimeTargetID: process.runtimeTargetID, terminalApp: process.terminalApp,
                windowID: process.windowID, terminalTrackingID: process.terminalTrackingID, terminalNativeID: process.terminalNativeID,
                terminalContainerID: process.terminalContainerID, pid: process.pid, status: process.status, logPath: process.logPath,
                lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: process.exitedAt)
            try restartProcessInTerminal(workspaceID: workspace.id, process: updatedProcess, templateOverride: desired.template)
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
                        terminalNativeID: window.terminalNativeID, terminalContainerID: window.terminalContainerID, role: window.role,
                        orderIndex: desiredOrder, lastSeenAt: window.lastSeenAt))
            }
        }
    }

    @discardableResult private func pruneMissingWindows(workspaceID: String) throws -> Int {
        let existingIDs = Set(try yabai.listWindows().map(\.id))
        let windows = try store.windows(workspaceID: workspaceID)
        let agentWindows = try store.agentWindows(workspaceID: workspaceID)
        var prunedTerminalTrackingKeys = Set<String>()
        var prunedTerminalWindowIDs = Set<Int>()
        var pruned = 0
        for window in windows {
            guard let id = window.windowID else {
                if managedTrackedTerminalWindowIsStillLive(window: window) { continue }
                if window.role == "terminal", let trackingKey = window.terminalTrackingKey { prunedTerminalTrackingKeys.insert(trackingKey) }
                try store.deleteWindow(id: window.id)
                pruned += 1
                continue
            }
            if !existingIDs.contains(id) {
                if managedTrackedTerminalWindowIsStillLive(window: window) {
                    if builtInTrackedWindowBelongsToAgent(window) {
                        try clearStaleBuiltInTerminalWindowBinding(window)
                        pruned += 1
                    }
                    continue
                }
                if window.role == "browser" { continue }
                if window.role == "terminal" {
                    prunedTerminalWindowIDs.insert(id)
                    if let trackingKey = window.terminalTrackingKey { prunedTerminalTrackingKeys.insert(trackingKey) }
                }
                try store.deleteWindow(id: window.id)
                pruned += 1
            }
        }
        pruned += try pruneOrphanedAgentWindows(
            workspaceID: workspaceID, agents: agentWindows, prunedTerminalTrackingKeys: prunedTerminalTrackingKeys,
            prunedTerminalWindowIDs: prunedTerminalWindowIDs)
        return pruned
    }

    private func managedTrackedTerminalWindowIsStillLive(window: WindowRecord) -> Bool {
        guard window.role == "terminal", let host = terminalHost(for: window.app) else { return false }
        guard host == .spaces else { return false }
        return builtInTrackedWindowIsStillLive(window: window)
    }

    private func builtInTrackedWindowIsStillLive(window: WindowRecord) -> Bool {
        guard window.role == "terminal", terminalHost(for: window.app) == .spaces else { return false }
        guard let sessionID = window.terminalNativeID ?? window.terminalTrackingID, !sessionID.isEmpty else { return false }
        if builtInSessionBelongsToRunningProcess(sessionID: sessionID, workspaceID: window.workspaceID) {
            return builtInSessionIsStillLive(sessionID: sessionID) || builtInSessionLaunchIsPending(sessionID: sessionID)
        }
        if builtInSessionBelongsToConfiguredAgent(sessionID: sessionID, workspaceID: window.workspaceID) {
            return builtInSessionIsStillLive(sessionID: sessionID) || builtInSessionLaunchIsPending(sessionID: sessionID)
        }
        if builtInSessionIsStillLive(sessionID: sessionID) && builtInSessionHasActiveAttachments(sessionID: sessionID) { return true }
        return builtInSessionLaunchIsPendingBeforeOwnerAttachment(sessionID: sessionID)
    }

    private func builtInTrackedWindowBelongsToAgent(_ window: WindowRecord) -> Bool {
        guard window.role == "terminal", terminalHost(for: window.app) == .spaces else { return false }
        guard let sessionID = window.terminalNativeID ?? window.terminalTrackingID, !sessionID.isEmpty else { return false }
        return builtInSessionBelongsToAgent(sessionID: sessionID, workspaceID: window.workspaceID)
    }

    private func builtInSessionIsStillLive(sessionID: String) -> Bool {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return false }
        guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { return false }
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else { return false }
        guard runtimeState.state == .starting || runtimeState.state == .running else { return false }
        return isProcessAlive(pid: Int(runtimeState.servicePID))
    }

    private func builtInSessionLaunchIsPending(sessionID: String, now: Date = Date()) -> Bool {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return false }
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths),
            runtimeState.state != .starting && runtimeState.state != .running
        {
            return false
        }
        guard let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths),
            let createdAt = ISO8601DateFormatter().date(from: launchConfiguration.createdAt)
        else { return false }
        let age = now.timeIntervalSince(createdAt)
        return age >= -5 && age < 60
    }

    private func builtInSessionLaunchIsPendingBeforeOwnerAttachment(sessionID: String, now: Date = Date()) -> Bool {
        guard !builtInSessionHasRecordedOwnerAttachment(sessionID: sessionID) else { return false }
        return builtInSessionLaunchIsPending(sessionID: sessionID, now: now)
    }

    private func builtInSessionHasRecordedOwnerAttachment(sessionID: String) -> Bool {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return false }
        guard let snapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths) else { return false }
        return snapshot.attachments.contains { $0.mode == .owner }
    }

    private func builtInAgentSessionIsStillLive(_ record: AgentWindowRecord) -> Bool {
        guard record.provider == .spaces else { return false }
        guard let sessionID = builtInAgentSessionID(for: record) else { return false }
        return builtInSessionIsStillLive(sessionID: sessionID)
    }

    private func builtInAgentSessionID(for record: AgentWindowRecord) -> String? {
        guard record.provider == .spaces else { return nil }
        let sessionID = record.terminalNativeID ?? record.terminalTrackingID
        guard let trimmed = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func builtInSessionBelongsToRunningProcess(sessionID: String, workspaceID: String) -> Bool {
        ((try? store.runningProcesses(workspaceID: workspaceID)) ?? []).contains { ($0.terminalNativeID ?? $0.terminalTrackingID) == sessionID }
    }

    private func builtInSessionBelongsToAgent(sessionID: String, workspaceID: String) -> Bool {
        ((try? store.agentWindows(workspaceID: workspaceID)) ?? []).contains { ($0.terminalNativeID ?? $0.terminalTrackingID) == sessionID }
    }

    private func builtInSessionBelongsToConfiguredAgent(sessionID: String, workspaceID: String) -> Bool {
        switch terminalSessionLaunchConfiguration(sessionID: sessionID)?.kind {
        case .agent: return true
        case .shell, .process: return false
        case nil: return ((try? store.agentWindows(workspaceID: workspaceID)) ?? []).contains { builtInTerminalSessionID(for: $0) == sessionID }
        }
    }

    private func builtInSessionHasActiveAttachments(sessionID: String) -> Bool {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return false }
        return ((try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []).isEmpty == false
    }

    @discardableResult private func pruneOrphanedAgentWindows(
        workspaceID: String, agents: [AgentWindowRecord], prunedTerminalTrackingKeys: Set<String>, prunedTerminalWindowIDs: Set<Int>
    ) throws -> Int {
        guard !prunedTerminalTrackingKeys.isEmpty || !prunedTerminalWindowIDs.isEmpty else { return 0 }
        let runningProcessTrackingKeys = Set(try store.runningProcesses(workspaceID: workspaceID).compactMap(\.terminalTrackingKey))
        var pruned = 0
        for agent in agents where TerminalHost(rawValue: agent.provider.rawValue) != nil {
            let trackingKey = agent.terminalTrackingKey
            let windowID = agent.yabaiWindowID ?? agent.windowID
            // Agent rows for ad-hoc terminals depend on the tracked terminal row for liveness.
            // Once that terminal disappears, the agent row should disappear too unless a managed
            // workspace process still owns the same terminal identity.
            let matchesPrunedTerminal =
                (trackingKey.map(prunedTerminalTrackingKeys.contains) ?? false) || (windowID.map(prunedTerminalWindowIDs.contains) ?? false)
            guard matchesPrunedTerminal else { continue }
            if let trackingKey, runningProcessTrackingKeys.contains(trackingKey) { continue }
            if try spacesAgentRecordIsConfiguredLauncher(workspaceID: workspaceID, record: agent) { continue }
            try store.deleteAgentWindow(id: agent.id)
            pruned += 1
        }
        return pruned
    }

    private func windowTrackingKey(_ window: WindowRecord) -> String {
        let idPart = window.windowID.map(String.init) ?? "none"
        if window.role == "browser" { return "browser:\(idPart):\(window.targetURL ?? "")" }
        if window.role == "terminal", window.windowID == nil {
            let app = window.app.lowercased()
            if let terminalNativeID = window.terminalNativeID, !terminalNativeID.isEmpty { return "terminal:\(app):native:\(terminalNativeID)" }
            if let terminalContainerID = window.terminalContainerID, !terminalContainerID.isEmpty {
                return "terminal:\(app):container:\(terminalContainerID)"
            }
            if let terminalTrackingID = window.terminalTrackingID, !terminalTrackingID.isEmpty {
                return "terminal:\(app):tracking:\(terminalTrackingID)"
            }
        }
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
                    id: UUID().uuidString, workspaceID: workspace.id, app: process.terminalApp ?? TerminalHost.spaces.appName,
                    name: process.templateName, detail: process.command, windowID: windowID, terminalTrackingID: process.terminalTrackingID,
                    role: "terminal", orderIndex: 200 + synthesized.count, lastSeenAt: nowISO8601()))
        }
        return synthesized
    }

    static func nextWindowOrderIndex(existing: [WindowRecord], role: String, orderOffset: Int) -> Int {
        let maxIndex = existing.filter { $0.role == role }.map(\.orderIndex).max() ?? (orderOffset - 1)
        return max(maxIndex + 1, orderOffset)
    }

    private func launchProcesses(workspace: WorkspaceRecord, templates: [ProcessTemplate], env: [String: String], background: Bool = false) throws
        -> [WindowRecord]
    {
        try requireWorkspaceSetupSucceeded(workspaceID: workspace.id)
        guard !templates.isEmpty else {
            try terminateBuiltInTerminalSessionsForConfiguredProcesses(workspaceID: workspace.id)
            try store.deleteRunningProcesses(workspaceID: workspace.id)
            return []
        }
        let terminalHost = try configuredTerminalHost()
        if terminalHost == .spaces {
            try terminateBuiltInTerminalSessionsForConfiguredProcesses(workspaceID: workspace.id)
            try store.deleteRunningProcesses(workspaceID: workspace.id)
            var terminalWindows: [WindowRecord] = []
            for (index, template) in templates.enumerated() {
                let name = template.name ?? template.command
                let sessionCommand = try spacesTerminalCommand(template: template, env: env)
                let session = try launchSpacesTerminalSession(
                    title: name, workingDirectory: workspace.dir, command: sessionCommand, showMode: .owner, backend: .ghosttyEmbedded,
                    readinessPolicy: .sessionReady, workspaceID: workspace.id, kind: .process)
                let now = nowISO8601()
                let running = RunningProcessRecord(
                    id: UUID().uuidString, workspaceID: workspace.id, templateID: template.id, templateName: name, command: template.command,
                    terminalApp: terminalAppName(for: terminalHost), windowID: session.windowID, terminalTrackingID: session.sessionID,
                    terminalNativeID: session.sessionID, terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: session.childPID,
                    status: .running, logPath: session.outputPath, lastOutputAt: nil, startedAt: now, exitedAt: nil)
                try store.upsert(runningProcess: running)
                terminalWindows.append(
                    WindowRecord(
                        id: UUID().uuidString, workspaceID: workspace.id, app: terminalAppName(for: terminalHost), name: name,
                        detail: template.command, targetURL: nil, windowID: session.windowID, terminalTrackingID: session.sessionID,
                        terminalNativeID: session.sessionID, terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal",
                        orderIndex: 200 + index, lastSeenAt: now))
            }
            return terminalWindows
        }
        guard terminalAdapterAvailable(terminalHost) else {
            throw WorkspaceError.dependencyMissing(message: missingTerminalDependencyMessage(for: terminalHost, operation: "launch processes"))
        }
        guard tmux.isAvailable() else { throw WorkspaceError.dependencyMissing(message: "tmux is required to launch processes.") }
        try terminateBuiltInTerminalSessionsForConfiguredProcesses(workspaceID: workspace.id)
        try store.deleteRunningProcesses(workspaceID: workspace.id)
        var terminalWindows: [WindowRecord] = []
        for (index, template) in templates.enumerated() {
            let name = template.name ?? template.command
            let command = try processLaunchCommand(template: template)
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
            let terminalContainerID = storedTerminalContainerID(terminalHost: terminalHost, handle: terminalHandle)
            let running = RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateID: template.id, templateName: name, command: template.command,
                terminalApp: terminalAppName(for: terminalHost), windowID: windowID, terminalTrackingID: hookSessionID,
                terminalNativeID: terminalNativeID, terminalContainerID: terminalContainerID, itermTabIndex: nil, tmuxWindowID: tmuxWindow?.id,
                pid: pid, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nowISO8601(), exitedAt: nil)
            try store.upsert(runningProcess: running)
            terminalWindows.append(
                WindowRecord(
                    id: running.id, workspaceID: workspace.id, app: terminalAppName(for: terminalHost), name: name, detail: template.command,
                    targetURL: nil, windowID: windowID, terminalTrackingID: hookSessionID, terminalNativeID: terminalNativeID,
                    terminalContainerID: terminalContainerID, itermTabIndex: nil, tmuxWindowID: tmuxWindow?.id, role: "terminal",
                    orderIndex: 200 + index, lastSeenAt: nowISO8601()))
        }
        return terminalWindows
    }

    private func ensureBrowserSessions(
        project: ProjectRecord, workspace: WorkspaceRecord, sessions: [BrowserSession], env: [String: String], extractOnAttach: Bool,
        background: Bool = false
    ) throws -> (windows: [WindowRecord], sessions: [BrowserSession]) {
        _ = project
        _ = extractOnAttach
        try requireWorkspaceSetupSucceeded(workspaceID: workspace.id)
        guard !sessions.isEmpty else { return ([], []) }
        guard chrome.isAvailable() else { throw WorkspaceError.dependencyMissing(message: "Google Chrome is required for browser sessions.") }
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

    private func captureCreatedAppWindow(snapshot: [YabaiWindow], appName: String) throws -> YabaiWindow? {
        let previousIDs = Set(snapshot.map(\.id))
        return try yabai.listWindows().first(where: { $0.app == appName && !previousIDs.contains($0.id) })
    }

    private func captureNewAppWindow(snapshot: [YabaiWindow], appName: String) throws -> YabaiWindow? {
        let current = try yabai.listWindows()
        if let created = try captureCreatedAppWindow(snapshot: snapshot, appName: appName) { return created }
        if let focused = try yabai.focusedWindow(), focused.app == appName { return focused }
        return current.filter { $0.app == appName }.sorted { $0.id > $1.id }.first
    }

    private func captureCreatedAppWindowID(snapshot: [YabaiWindow], appName: String) throws -> Int? {
        try captureCreatedAppWindow(snapshot: snapshot, appName: appName)?.id
    }

    private func captureNewAppWindowID(snapshot: [YabaiWindow], appName: String) throws -> Int? {
        try captureNewAppWindow(snapshot: snapshot, appName: appName)?.id
    }

    private func captureSummonedBuiltInTerminalWindowID(appName: String) throws -> Int? {
        if let focused = try? yabai.focusedWindow(), focused.app == appName { return focused.id }
        return try yabai.listWindows().filter { $0.app == appName }.sorted { $0.id > $1.id }.first?.id
    }

    private func bestEffortYabaiWindowSnapshot() -> [YabaiWindow] { (try? yabai.listWindows()) ?? [] }

    private func bestEffortCaptureNewAppWindowID(snapshot: [YabaiWindow], appName: String) -> Int? {
        try? captureCreatedAppWindowID(snapshot: snapshot, appName: appName)
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

    private func runtimeDirectory() throws -> String { try SpacesProfile.current().runtimeDirectory }

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
            guard isManagedTerminalApp(process.terminalApp) else { return pid }
            if let builtInSessionRuntimePID = resolvedBuiltInSessionRuntimePID(for: process), isProcessAlive(pid: builtInSessionRuntimePID) {
                return builtInSessionRuntimePID
            }
            guard let pidFile = try? processRuntimePaths(workspaceID: process.workspaceID, name: process.templateName).pidFile else { return pid }
            if let runtimePID = runtimePID(fromFile: pidFile), runtimePID > 0, isProcessAlive(pid: runtimePID) { return runtimePID }
            return pid
        }
        guard isManagedTerminalApp(process.terminalApp) else { return nil }
        if let builtInSessionRuntimePID = resolvedBuiltInSessionRuntimePID(for: process), isProcessAlive(pid: builtInSessionRuntimePID) {
            return builtInSessionRuntimePID
        }
        guard let pidFile = try? processRuntimePaths(workspaceID: process.workspaceID, name: process.templateName).pidFile else { return nil }
        return runtimePID(fromFile: pidFile)
    }

    private func resolvedBuiltInSessionRuntimePID(for process: RunningProcessRecord) -> Int? {
        resolvedBuiltInSessionRuntimeState(for: process)?.childPID.map(Int.init)
    }

    private func resolvedBuiltInSessionRuntimeState(for process: RunningProcessRecord) -> TerminalSessionRuntimeState? {
        guard terminalHost(for: process.terminalApp) == .spaces else { return nil }
        guard let sessionID = process.terminalNativeID ?? process.terminalTrackingID, !sessionID.isEmpty else { return nil }
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return nil }
        return try? TerminalSessionPersistence.readRuntimeState(paths: paths)
    }

    private func runtimePID(fromFile path: String) -> Int? {
        guard let contents = try? String(contentsOfFile: path) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int(trimmed), pid > 0 else { return nil }
        return pid
    }

    private func isProcessAlive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if let state = processState(pid: pid) {
            let trimmed = state.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = trimmed.first, first == "Z" { return false }
            return !trimmed.isEmpty
        }
        // If the PID is dead, check if any child processes are still alive.
        // This handles cases where the shell exits but the actual command continues.
        guard let output = try? Shell.runAndCapture(["pgrep", "-P", "\(pid)"]) else { return false }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    private func processState(pid: Int) -> String? {
        guard pid > 0 else { return nil }
        if Darwin.kill(pid_t(pid), 0) != 0, errno != EPERM { return nil }
        return try? Shell.runAndCapture(["ps", "-p", "\(pid)", "-o", "state="])
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

    private func standardizePathPreservingSymlinks(_ path: String) -> String {
        let expanded = expandTilde(path)
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func normalizePathPreservingLeaf(_ path: String) -> String {
        let expanded = expandTilde(path)
        let url = URL(fileURLWithPath: expanded)
        let normalizedParent = normalizePath(url.deletingLastPathComponent().path)
        return URL(fileURLWithPath: normalizedParent, isDirectory: true).appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
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
        let projectDirname = managedProjectStorageDirectoryName(projectID: project.id, preferredName: project.name)
        return workspaceRootDirectory().appending(path: projectDirname, directoryHint: .isDirectory)
    }

    private func gitProjectImportPlan(gitURL: String) throws -> GitProjectImportPlan {
        let trimmedURL = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { throw WorkspaceError.invalidArgument(message: "Git repository URL is required.") }
        let inferredName = inferredProjectName(from: trimmedURL)
        let projectID = projectID(namespace: "git", source: trimmedURL)
        let projectName = sanitizeDirname(inferredName, fallback: "project")
        let projectDirname = managedProjectStorageDirectoryName(projectID: projectID, preferredName: projectName)
        let destination = repositoriesRootDirectory().appending(path: projectDirname, directoryHint: .isDirectory)
        let normalizedDestination = normalizePathPreservingLeaf(destination.path)
        let project = ProjectRecord(id: projectID, name: projectName, dir: normalizedDestination, isGitRepo: true, defaultBranch: nil)
        return GitProjectImportPlan(gitURL: trimmedURL, project: project, destination: destination)
    }

    private func managedGitProjectImportReplacementCandidates(plan: GitProjectImportPlan) throws -> [ManagedDirectoryReplacementCandidate] {
        try validateManagedGitProjectImportDirectoriesAreUnowned(plan: plan)
        var candidates: [ManagedDirectoryReplacementCandidate] = []
        if let projectCandidate = try managedDirectoryReplacementCandidate(path: plan.destination.path, kind: .projectRepository) {
            candidates.append(projectCandidate)
        }
        if let workspaceCandidate = try managedDirectoryReplacementCandidate(
            path: worktreeRoot(project: plan.project).path, kind: .workspaceDirectory)
        {
            candidates.append(workspaceCandidate)
        }
        return candidates
    }

    private func validateManagedGitProjectImportDirectoriesAreUnowned(plan: GitProjectImportPlan) throws {
        try validateManagedDirectoryIsUnowned(path: plan.destination.path)
        try validateManagedDirectoryIsUnowned(path: worktreeRoot(project: plan.project).path)
    }

    private func replaceManagedGitProjectImportDirectoriesIfNeeded(plan: GitProjectImportPlan, allowReplacement: Bool) throws {
        let candidates = try managedGitProjectImportReplacementCandidates(plan: plan)
        guard !candidates.isEmpty else { return }
        guard allowReplacement else {
            throw WorkspaceError.invalidArgument(
                message: "Managed project import folders already exist: \(candidates.map(\.path).joined(separator: ", "))")
        }
        let orderedCandidates = candidates.sorted { lhs, rhs in lhs.kind == .workspaceDirectory && rhs.kind == .projectRepository }
        for candidate in orderedCandidates { try removeReplaceableManagedDirectory(candidate) }
    }

    private func replaceManagedWorkspaceDirectoryIfNeeded(path: String, allowReplacement: Bool) throws {
        guard let candidate = try managedDirectoryReplacementCandidate(path: path, kind: .workspaceDirectory) else { return }
        guard allowReplacement else { throw WorkspaceError.invalidArgument(message: "Workspace directory already exists: \(candidate.path)") }
        try removeReplaceableManagedDirectory(candidate)
    }

    func managedDirectoryReplacementCandidate(path: String, kind: ManagedDirectoryReplacementCandidate.Kind) throws
        -> ManagedDirectoryReplacementCandidate?
    {
        let managedPath = standardizePathPreservingSymlinks(path)
        switch kind {
        case .projectRepository:
            guard isManagedRepositoryEntryPath(managedPath) else { return nil }
            guard !hasSymlinkedAncestorBelowManagedRoot(path: managedPath, rootPath: repositoriesRootDirectory().path) else { return nil }
        case .workspaceDirectory:
            guard isManagedWorkspaceEntryPath(managedPath) else { return nil }
            guard !hasSymlinkedAncestorBelowManagedRoot(path: managedPath, rootPath: workspaceRootDirectory().path) else { return nil }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: managedPath, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        try validateManagedDirectoryIsUnowned(path: managedPath)
        return ManagedDirectoryReplacementCandidate(kind: kind, path: managedPath)
    }

    private func removeReplaceableManagedDirectory(_ candidate: ManagedDirectoryReplacementCandidate) throws {
        guard let revalidated = try managedDirectoryReplacementCandidate(path: candidate.path, kind: candidate.kind) else { return }
        if revalidated.kind == .workspaceDirectory { try removeRegisteredGitWorktreeForReplacementIfNeeded(path: revalidated.path) }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: revalidated.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        try FileManager.default.removeItem(atPath: revalidated.path)
    }

    private enum ManagedDirectoryOwnershipConflict {
        case project(String)
        case workspace(WorkspaceRecord)
        case descendant(String)
    }

    private func validateManagedDirectoryIsUnowned(path: String) throws {
        guard let conflict = try managedDirectoryOwnershipConflict(path: path) else { return }
        switch conflict {
        case .project(let path): throw WorkspaceError.projectAlreadyExists(dir: path)
        case .workspace(let workspace): throw WorkspaceError.invalidArgument(message: "Workspace already exists: \(workspace.title)")
        case .descendant(let path):
            throw WorkspaceError.invalidArgument(message: "Managed folder contains a project or workspace owned by Spaces: \(path)")
        }
    }

    private func managedDirectoryOwnershipConflict(path: String) throws -> ManagedDirectoryOwnershipConflict? {
        let entryPath = standardizePathPreservingSymlinks(path)
        let resolvedPath = normalizePath(entryPath)
        var ownershipPaths = [entryPath]
        if resolvedPath != entryPath { ownershipPaths.append(resolvedPath) }
        for ownershipPath in ownershipPaths {
            if try store.project(dir: ownershipPath) != nil { return .project(ownershipPath) }
            if let workspace = try store.workspace(dir: ownershipPath) { return .workspace(workspace) }
        }
        for ownershipPath in ownershipPaths where try managedDirectoryContainsOwnedDescendant(path: ownershipPath) {
            return .descendant(ownershipPath)
        }
        return nil
    }

    private func removeRegisteredGitWorktreeForReplacementIfNeeded(path: String) throws {
        let entryPath = standardizePathPreservingSymlinks(path)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: entryPath)) == nil else { return }
        let resolvedPath = normalizePath(entryPath)
        for project in try store.projects() where project.isGitRepo {
            let rootPath = standardizePathPreservingSymlinks(try worktreeRoot(project: project).path)
            guard entryPath != rootPath, isPathPreservingSymlinks(entryPath, inside: rootPath) else { continue }
            let worktrees = try git.listWorktrees(path: project.dir)
            let isRegistered = worktrees.contains {
                let worktreePath = standardizePathPreservingSymlinks($0.path)
                return worktreePath == entryPath || normalizePath(worktreePath) == resolvedPath
            }
            guard isRegistered else { return }
            do { try git.removeWorktree(path: project.dir, worktreePath: entryPath) } catch {
                guard isMissingWorktreeError(error) else { throw error }
                try git.pruneWorktrees(path: project.dir)
                let prunedWorktrees = try git.listWorktrees(path: project.dir)
                if prunedWorktrees.contains(where: {
                    let worktreePath = standardizePathPreservingSymlinks($0.path)
                    return worktreePath == entryPath || normalizePath(worktreePath) == resolvedPath
                }) {
                    throw error
                }
            }
            return
        }
    }

    private func hasSymlinkedAncestorBelowManagedRoot(path: String, rootPath: String) -> Bool {
        let root = URL(fileURLWithPath: standardizePathPreservingSymlinks(rootPath), isDirectory: true)
        let candidate = URL(fileURLWithPath: standardizePathPreservingSymlinks(path), isDirectory: true)
        let rootComponentCount = root.pathComponents.count
        var ancestor = candidate.deletingLastPathComponent()
        while ancestor.pathComponents.count > rootComponentCount {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil { return true }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            ancestor = parent
        }
        return false
    }

    private func managedDirectoryContainsOwnedDescendant(path: String) throws -> Bool {
        for project in try store.projects() {
            let projectPath = normalizePath(project.dir)
            if projectPath != path, isPath(projectPath, inside: path) { return true }
            for workspace in try store.workspaces(projectID: project.id, includeArchived: true) {
                let workspacePath = normalizePath(workspace.dir)
                if workspacePath != path, isPath(workspacePath, inside: path) { return true }
            }
        }
        return false
    }

    private func makeWorkspaceDirname(
        project: ProjectRecord, preferredExistingDirname: String?, requestedDirname: String?, excludingDirname: String?,
        excludingFilesystemDirname: String? = nil
    ) throws -> String {
        if let requestedDirname, !requestedDirname.isEmpty {
            try validateWorkspaceDirname(requestedDirname)
            let used = try usedWorkspaceDirnames(
                project: project, excludingDirname: excludingDirname, excludingFilesystemDirname: excludingFilesystemDirname)
            guard !used.contains(requestedDirname) else {
                throw WorkspaceError.invalidArgument(message: "Workspace directory name is already in use: \(requestedDirname)")
            }
            return requestedDirname
        }
        let used = try usedWorkspaceDirnames(project: project, excludingDirname: excludingDirname)
        if let preferredExistingDirname, !preferredExistingDirname.isEmpty, !used.contains(preferredExistingDirname) {
            return preferredExistingDirname
        }
        if let available = WorkspaceOrchestrator.workspaceFoodNames.first(where: { !used.contains($0) }) { return available }
        throw WorkspaceError.invalidArgument(message: "No available workspace dirnames remain for project \(project.name).")
    }

    private func usedWorkspaceDirnames(project: ProjectRecord, excludingDirname: String?, excludingFilesystemDirname: String? = nil) throws -> Set<
        String
    > {
        let records = try store.workspaces(projectID: project.id, includeArchived: true)
        var used = Set<String>()
        for record in records {
            if project.isGitRepo, record.isArchived { continue }
            if let dirname = record.dirname, !dirname.isEmpty, dirname != excludingDirname { used.insert(dirname) }
        }
        let root = try worktreeRoot(project: project)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for entry in entries where entry != excludingDirname && entry != excludingFilesystemDirname { used.insert(entry) }
        }
        return used
    }

    private func validateWorkspaceDirname(_ dirname: String) throws {
        guard !dirname.isEmpty else { throw WorkspaceError.invalidArgument(message: "Workspace directory name cannot be empty.") }
        if dirname.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            throw WorkspaceError.invalidArgument(message: "Workspace directory name cannot contain spaces.")
        }
        for scalar in dirname.unicodeScalars {
            guard scalar.isASCII else {
                throw WorkspaceError.invalidArgument(message: "Workspace directory name can only use letters, numbers, '-', and '_'.")
            }
            let value = scalar.value
            let isUppercaseLetter = value >= 65 && value <= 90
            let isLowercaseLetter = value >= 97 && value <= 122
            let isDigit = value >= 48 && value <= 57
            let isHyphen = value == 45
            let isUnderscore = value == 95
            guard isUppercaseLetter || isLowercaseLetter || isDigit || isHyphen || isUnderscore else {
                throw WorkspaceError.invalidArgument(message: "Workspace directory name can only use letters, numbers, '-', and '_'.")
            }
        }
    }

    private func isMissingWorktreeError(_ error: Error) -> Bool {
        guard case WorkspaceError.gitCommandFailed(let message) = error else { return false }
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

    private func managedProjectStorageDirectoryName(projectID: String, preferredName: String) -> String {
        let sanitizedName = sanitizeDirname(preferredName, fallback: "project")
        let hashSuffix = String(projectID.lowercased().prefix(16))
        let maxNameLength = max(1, 255 - hashSuffix.count - 1)
        let truncatedName = String(sanitizedName.prefix(maxNameLength))
        return "\(truncatedName)-\(hashSuffix)"
    }

    private func projectID(namespace: String, source: String) -> String {
        let data = Data("\(namespace)\u{0}\(source)".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func repositoriesRootDirectory() -> URL {
        if let projectsRootDirectoryURL { return projectsRootDirectoryURL }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "spaces", directoryHint: .isDirectory).appending(path: "repos", directoryHint: .isDirectory)
    }

    private func workspaceRootDirectory() -> URL {
        if let workspacesRootDirectoryURL { return workspacesRootDirectoryURL }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "spaces", directoryHint: .isDirectory).appending(path: "workspaces", directoryHint: .isDirectory)
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

    private func removePreparedManagedGitWorkspaceRootIfUnowned(project: ProjectRecord) throws {
        guard project.isGitRepo else { return }
        let root = try worktreeRoot(project: project)
        guard isManagedWorkspaceEntryPath(root.path) else { return }
        try removePreparedManagedDirectoryIfUnowned(path: root.path)
    }

    private func removePreparedManagedProjectDirectoryIfUnowned(project: ProjectRecord) throws {
        guard project.isGitRepo, isManagedRepositoryDirectory(path: project.dir) else { return }
        try removePreparedManagedDirectoryIfUnowned(path: project.dir)
    }

    private func removePreparedManagedDirectoryIfUnowned(path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        if case .some = try managedDirectoryOwnershipConflict(path: path) { return }
        try FileManager.default.removeItem(atPath: path)
    }

    func rollbackFailedImportedProjectCreation(project: ProjectRecord, workspaceDirectory: String) throws {
        let workspaces = try store.workspaces(projectID: project.id, includeArchived: true)
        let portAllocator = PortAllocator(store: store)
        for workspace in workspaces { try portAllocator.releasePorts(workspaceID: workspace.id) }
        try store.deleteProject(id: project.id)
        try removeManagedWorkspaceDirectoryIfNeeded(path: workspaceDirectory)
        try removeManagedProjectDirectoryIfNeeded(project: project)
    }

    private func isManagedRepositoryDirectory(path: String) -> Bool { isPath(path, inside: repositoriesRootDirectory().path) }

    private func isManagedRepositoryEntryPath(_ path: String) -> Bool { isPathPreservingSymlinks(path, inside: repositoriesRootDirectory().path) }

    private func defaultWorkspace(projectID: String) throws -> WorkspaceRecord? {
        try store.workspaces(projectID: projectID, includeArchived: true).first(where: \.isDefault)
    }

    private func preferredImportedDefaultBranch(path: String) throws -> String {
        if git.branchExists(path: path, branch: "main") { return "main" }
        if git.branchExists(path: path, branch: "master") { return "master" }
        throw WorkspaceError.invalidArgument(message: "Imported git repository must contain a main or master branch.")
    }

    private func importedDefaultWorkspaceDirectory(project: ProjectRecord, branch: String) throws -> String {
        let root = try worktreeRoot(project: project)
        return root.appendingPathComponent(branch, isDirectory: true).path
    }

    private func isManagedWorkspacesDirectory(path: String, allowEqual: Bool = false) -> Bool {
        isPath(path, inside: workspaceRootDirectory().path, allowEqual: allowEqual)
    }

    private func isManagedWorkspaceEntryPath(_ path: String, allowEqual: Bool = false) -> Bool {
        isPathPreservingSymlinks(path, inside: workspaceRootDirectory().path, allowEqual: allowEqual)
    }

    private func removeManagedWorkspaceDirectoryIfNeeded(path: String) throws {
        let normalizedPath = normalizePath(path)
        guard isManagedWorkspacesDirectory(path: normalizedPath) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        try FileManager.default.removeItem(atPath: normalizedPath)
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

    private func isPathPreservingSymlinks(_ path: String, inside rootPath: String, allowEqual: Bool = false) -> Bool {
        let root = URL(fileURLWithPath: standardizePathPreservingSymlinks(rootPath), isDirectory: true)
        let candidate = URL(fileURLWithPath: standardizePathPreservingSymlinks(path), isDirectory: true)
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
        workspaceID: String, terminalTrackingID: String?, codexThreadID: String?, yabaiWindowID: Int?, label: String? = nil,
        provider: AgentProvider? = nil, allowLabelFallbackWithExplicitIdentity: Bool = false
    ) throws -> AgentWindowRecord? {
        let allAgentWindows = try store.agentWindows(workspaceID: workspaceID)
        let hasExplicitIdentity = {
            if let terminalTrackingID, !terminalTrackingID.isEmpty { return true }
            if let codexThreadID, !codexThreadID.isEmpty { return true }
            if yabaiWindowID != nil { return true }
            return false
        }()
        return terminalTrackingID.flatMap { sessionID in allAgentWindows.first(where: { $0.terminalTrackingID == sessionID }) }
            ?? yabaiWindowID.flatMap { windowID in allAgentWindows.first(where: { ($0.yabaiWindowID ?? $0.windowID) == windowID }) }
            ?? allAgentWindows.first(where: { $0.codexThreadID == codexThreadID && codexThreadID != nil })
            ?? ((!hasExplicitIdentity || allowLabelFallbackWithExplicitIdentity)
                ? label.flatMap { label in
                    allAgentWindows.first { record in record.label == label && (provider == nil || record.provider == provider) }
                } : nil)
    }

    private func agentTerminalTargetID(terminalTrackingID: String?, yabaiWindowID: Int?) -> String? {
        if let sessionID = terminalTrackingID, !sessionID.isEmpty { return "terminal:\(sessionID)" }
        if let windowID = yabaiWindowID { return "window:\(windowID)" }
        return nil
    }

    private func ignoresUntrustedSpacesAgentYabaiWindowID(provider: AgentProvider, terminalTrackingID: String?, terminalNativeID: String?) -> Bool {
        func isBuiltInSpacesTerminalIdentity(_ value: String?) -> Bool {
            guard let value, !value.isEmpty else { return false }
            return UUID(uuidString: value) != nil
        }

        return provider == .spaces && [terminalTrackingID, terminalNativeID].contains(where: isBuiltInSpacesTerminalIdentity)
    }

    private func trustedAgentYabaiWindowID(provider: AgentProvider, terminalTrackingID: String?, terminalNativeID: String?, yabaiWindowID: Int?)
        -> Int?
    {
        ignoresUntrustedSpacesAgentYabaiWindowID(provider: provider, terminalTrackingID: terminalTrackingID, terminalNativeID: terminalNativeID)
            ? nil : yabaiWindowID
    }

    private func matchedWorkspaceProcessForAgent(workspaceID: String, provider: AgentProvider, terminalTrackingID: String?, yabaiWindowID: Int?)
        throws -> RunningProcessRecord?
    {
        let processes = try store.runningProcesses(workspaceID: workspaceID)
        let targetID = agentTerminalTargetID(terminalTrackingID: terminalTrackingID, yabaiWindowID: yabaiWindowID)
        if let targetID, let matched = processes.first(where: { $0.terminalTrackingKey == targetID }) { return matched }
        return processes.first(where: { process in
            guard terminalHost(for: process.terminalApp)?.rawValue == provider.rawValue else { return false }
            if let terminalTrackingID, !terminalTrackingID.isEmpty, process.terminalTrackingID == terminalTrackingID { return true }
            if let terminalTrackingID, !terminalTrackingID.isEmpty {
                guard process.terminalTrackingID == nil || process.terminalTrackingID?.isEmpty == true else { return false }
            }
            if let yabaiWindowID, process.windowID == yabaiWindowID { return true }
            return false
        })
    }

    private func matchedTrackedWindowForAgent(workspaceID: String, provider: AgentProvider, terminalTrackingID: String?, yabaiWindowID: Int?) throws
        -> WindowRecord?
    {
        let windows = try store.windows(workspaceID: workspaceID)
        if provider == .spaces, let terminalTrackingID, !terminalTrackingID.isEmpty,
            let trackedWindow = windows.first(where: {
                $0.role == "terminal" && $0.app == (TerminalHost(rawValue: provider.rawValue)?.appName ?? provider.rawValue)
                    && $0.terminalTrackingID == terminalTrackingID
            })
        {
            return trackedWindow
        }
        if let targetID = agentTerminalTargetID(terminalTrackingID: terminalTrackingID, yabaiWindowID: yabaiWindowID),
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
    ) throws -> WindowRecord? {
        let trustedYabaiWindowID = trustedAgentYabaiWindowID(
            provider: provider, terminalTrackingID: terminalTrackingID, terminalNativeID: terminalNativeID, yabaiWindowID: yabaiWindowID)

        if let trackedWindow = try matchedTrackedWindowForAgent(
            workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID, yabaiWindowID: trustedYabaiWindowID, )
        {
            let liveWindow = trustedYabaiWindowID.flatMap { (try? yabai.window(id: $0)) ?? nil }
            let resolvedWindowID = trustedYabaiWindowID ?? trackedWindow.windowID
            let resolvedSessionID = terminalTrackingID ?? trackedWindow.terminalTrackingID
            let resolvedNativeID = terminalNativeID ?? trackedWindow.terminalNativeID
            if resolvedWindowID != trackedWindow.windowID || resolvedSessionID != trackedWindow.terminalTrackingID
                || resolvedNativeID != trackedWindow.terminalNativeID
            {
                let updated = WindowRecord(
                    id: trackedWindow.id, workspaceID: trackedWindow.workspaceID, app: liveWindow?.app ?? trackedWindow.app, name: trackedWindow.name,
                    detail: trackedWindow.detail, targetURL: trackedWindow.targetURL, windowID: resolvedWindowID,
                    terminalTrackingID: resolvedSessionID, terminalNativeID: resolvedNativeID, terminalContainerID: trackedWindow.terminalContainerID,
                    role: trackedWindow.role, orderIndex: trackedWindow.orderIndex, lastSeenAt: nowISO8601())
                try store.upsert(window: updated)
                return updated
            }
            return trackedWindow
        }
        guard let yabaiWindowID = trustedYabaiWindowID else { return nil }
        let liveWindow = (try? yabai.window(id: yabaiWindowID)) ?? nil
        let existing = try store.windows(workspaceID: workspaceID)
        let record = WindowRecord(
            id: UUID().uuidString, workspaceID: workspaceID,
            app: liveWindow?.app ?? (TerminalHost(rawValue: provider.rawValue)?.appName ?? provider.rawValue),
            name: liveWindow?.title ?? label ?? "Coding Agent CLI", detail: nil, windowID: yabaiWindowID, terminalTrackingID: terminalTrackingID,
            terminalNativeID: terminalNativeID, terminalContainerID: nil, role: "terminal",
            orderIndex: Self.nextWindowOrderIndex(existing: existing, role: "terminal", orderOffset: 200), lastSeenAt: nowISO8601())
        try store.upsert(window: record)
        return record
    }

    private func agentWindowIsOpen(_ windowID: Int?) -> Bool {
        guard let windowID, let liveWindow = (try? yabai.window(id: windowID)) ?? nil else { return false }
        return liveWindow.id == windowID
    }

    private func removeStaleAgentWindow(_ record: AgentWindowRecord) throws {
        terminateBuiltInTerminalSession(record.terminalNativeID ?? record.terminalTrackingID)
        try store.deleteAgentWindow(id: record.id)
        try removeAdHocTrackedWindowForAgent(
            workspaceID: record.workspaceID, provider: record.provider, terminalTrackingID: record.terminalTrackingID,
            yabaiWindowID: record.yabaiWindowID ?? record.windowID)
    }

    private func removeAdHocTrackedWindowForAgent(workspaceID: String, provider: AgentProvider, terminalTrackingID: String?, yabaiWindowID: Int?)
        throws
    {
        guard
            let trackedWindow = try matchedTrackedWindowForAgent(
                workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID, yabaiWindowID: yabaiWindowID)
        else { return }
        let processUsesWindow = try store.runningProcesses(workspaceID: workspaceID).contains { process in
            process.terminalTrackingKey == trackedWindow.terminalTrackingKey
        }
        if !processUsesWindow { try store.deleteWindow(id: trackedWindow.id) }
    }

    private func agentSessionEventMessage(
        provider: AgentProvider, label: String?, terminalTrackingID: String?, terminalNativeID: String?, codexThreadID: String?, yabaiWindowID: Int?,
        environmentKeys: [String]? = nil
    ) -> String {
        func normalizedValue(_ value: String?) -> String {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return "<nil>" }
            return value
        }

        let normalizedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelValue = (normalizedLabel?.isEmpty == false ? normalizedLabel : nil) ?? "<nil>"
        let trackingValue = normalizedValue(terminalTrackingID)
        let nativeValue = normalizedValue(terminalNativeID)
        let threadValue = normalizedValue(codexThreadID)
        let windowValue = yabaiWindowID.map(String.init) ?? "<nil>"
        let envKeysValue = environmentKeys.map { $0.isEmpty ? "<none>" : $0.joined(separator: ",") } ?? "<nil>"
        return
            "provider=\(provider.rawValue) label=\(labelValue) tracking_id=\(trackingValue) native_id=\(nativeValue) codex_thread_id=\(threadValue) yabai_window_id=\(windowValue) env_keys=\(envKeysValue)"
    }

    private func appendAgentSessionEvent(agentSessionID: String, eventType: String, source: String, message: String?, createdAt: String) {
        let runtimeTargetID = try? store.agentSessionRuntimeTargetID(id: agentSessionID)
        try? store.appendAgentSessionEvent(
            agentSessionID: agentSessionID, eventType: eventType, source: source, message: message, runtimeTargetID: runtimeTargetID,
            createdAt: createdAt)
    }

    private func spacesAgentLabelMatchesConfiguredLauncher(workspaceID: String, label: String?) throws -> Bool {
        guard let normalizedLabel = label.map(normalizedFocusName), !normalizedLabel.isEmpty else { return false }
        return try store.workspaceAgentLaunchers(workspaceID: workspaceID).contains { normalizedFocusName($0.name) == normalizedLabel }
    }

    private func spacesAgentRecordIsConfiguredLauncher(workspaceID: String, record: AgentWindowRecord, fallbackLabel: String? = nil) throws -> Bool {
        guard record.provider == .spaces else { return false }
        let launcherNames = Set(try store.workspaceAgentLaunchers(workspaceID: workspaceID).map { normalizedFocusName($0.name) })
        guard !launcherNames.isEmpty else { return false }
        let candidateNames = [record.claimedLauncherName, record.label, fallbackLabel].compactMap(sanitizedFocusName).map(normalizedFocusName)
        return candidateNames.contains { launcherNames.contains($0) }
    }

    @discardableResult public func registerAgentWindow(
        workspaceID: String, provider: AgentProvider, label: String? = nil, terminalTrackingID: String? = nil, terminalNativeID: String? = nil,
        codexThreadID: String? = nil, yabaiWindowID: Int? = nil, status: AgentWindowStatus = .idle, claimedLauncherID: String? = nil,
        claimedLauncherName: String? = nil, eventType: String = "register", eventSource: String = "orchestrator", environmentKeys: [String]? = nil
    ) throws -> AgentWindowRecord {
        let now = nowISO8601()
        let existingAgentWindows = try store.agentWindows(workspaceID: workspaceID)
        let trustedYabaiWindowID = trustedAgentYabaiWindowID(
            provider: provider, terminalTrackingID: terminalTrackingID, terminalNativeID: terminalNativeID, yabaiWindowID: yabaiWindowID)
        let matchedProcess = try matchedWorkspaceProcessForAgent(
            workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID, yabaiWindowID: trustedYabaiWindowID)
        let resolvedTerminalNativeID = matchedProcess?.terminalNativeID ?? terminalNativeID
        let resolvedTrustedYabaiWindowID = trustedAgentYabaiWindowID(
            provider: provider, terminalTrackingID: terminalTrackingID, terminalNativeID: resolvedTerminalNativeID, yabaiWindowID: yabaiWindowID)
        let trackedWindow = try ensureTrackedWindowExistsForAgent(
            workspaceID: workspaceID, provider: provider, label: label, terminalTrackingID: terminalTrackingID,
            terminalNativeID: resolvedTerminalNativeID, yabaiWindowID: resolvedTrustedYabaiWindowID)
        let resolvedWindowID = trackedWindow?.windowID ?? resolvedTrustedYabaiWindowID
        let finalTerminalNativeID = trackedWindow?.terminalNativeID ?? resolvedTerminalNativeID
        let allowConfiguredSpacesLabelFallback: Bool
        if provider == .spaces {
            let matchesConfiguredLauncher = try spacesAgentLabelMatchesConfiguredLauncher(workspaceID: workspaceID, label: label)
            allowConfiguredSpacesLabelFallback = claimedLauncherID != nil || claimedLauncherName != nil || matchesConfiguredLauncher
        } else {
            allowConfiguredSpacesLabelFallback = false
        }
        if let existing = try matchingAgentWindow(
            workspaceID: workspaceID, terminalTrackingID: terminalTrackingID, codexThreadID: codexThreadID, yabaiWindowID: resolvedWindowID,
            label: label, provider: provider, allowLabelFallbackWithExplicitIdentity: allowConfiguredSpacesLabelFallback)
        {
            let resolvedClaimedLauncherName = claimedLauncherName ?? existing.claimedLauncherName
            let resolvedLabel = try uniqueAgentFocusLabel(
                workspaceID: workspaceID, preferredLabel: label ?? existing.label, excludingAgentWindowID: existing.id,
                claimedLauncherName: resolvedClaimedLauncherName)
            let updated = AgentWindowRecord(
                id: existing.id, workspaceID: existing.workspaceID, provider: existing.provider, label: resolvedLabel,
                runtimeTargetID: existing.runtimeTargetID ?? trackedWindow?.id,
                terminalTarget: TerminalTargetRecord(
                    runtimeTargetID: existing.runtimeTargetID ?? trackedWindow?.id,
                    windowID: resolvedWindowID
                        ?? (ignoresUntrustedSpacesAgentYabaiWindowID(
                            provider: provider, terminalTrackingID: terminalTrackingID, terminalNativeID: finalTerminalNativeID)
                            ? nil : existing.windowID),
                    trackingID: terminalTrackingID ?? finalTerminalNativeID ?? existing.terminalTrackingID),
                sessionKey: codexThreadID ?? existing.codexThreadID, claimedLauncherID: claimedLauncherID ?? existing.claimedLauncherID,
                claimedLauncherName: resolvedClaimedLauncherName, status: status, createdAt: existing.createdAt, updatedAt: now)
            try validateWorkspaceFocusNames(
                workspaceID: workspaceID, processes: try store.workspaceProcesses(workspaceID: workspaceID),
                browserSessions: try store.workspaceBrowserSessions(workspaceID: workspaceID),
                agentWindows: existingAgentWindows.map { $0.id == existing.id ? updated : $0 })
            try store.upsertAgentWindow(updated)
            appendAgentSessionEvent(
                agentSessionID: updated.id, eventType: eventType, source: eventSource,
                message: agentSessionEventMessage(
                    provider: updated.provider, label: updated.label, terminalTrackingID: updated.terminalTrackingID,
                    terminalNativeID: updated.terminalNativeID, codexThreadID: updated.codexThreadID, yabaiWindowID: updated.yabaiWindowID,
                    environmentKeys: environmentKeys), createdAt: now)
            return updated
        }
        let resolvedLabel = try uniqueAgentFocusLabel(workspaceID: workspaceID, preferredLabel: label, claimedLauncherName: claimedLauncherName)
        let record = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspaceID, provider: provider, label: resolvedLabel, runtimeTargetID: trackedWindow?.id,
            terminalTarget: TerminalTargetRecord(
                runtimeTargetID: trackedWindow?.id, windowID: resolvedWindowID, trackingID: terminalTrackingID ?? finalTerminalNativeID),
            sessionKey: codexThreadID, claimedLauncherID: claimedLauncherID, claimedLauncherName: claimedLauncherName, status: status, createdAt: now,
            updatedAt: now)
        try validateWorkspaceFocusNames(
            workspaceID: workspaceID, processes: try store.workspaceProcesses(workspaceID: workspaceID),
            browserSessions: try store.workspaceBrowserSessions(workspaceID: workspaceID), agentWindows: existingAgentWindows + [record])
        try store.upsertAgentWindow(record)
        appendAgentSessionEvent(
            agentSessionID: record.id, eventType: eventType, source: eventSource,
            message: agentSessionEventMessage(
                provider: record.provider, label: record.label, terminalTrackingID: record.terminalTrackingID,
                terminalNativeID: record.terminalNativeID, codexThreadID: record.codexThreadID, yabaiWindowID: record.yabaiWindowID,
                environmentKeys: environmentKeys), createdAt: now)
        return record
    }

    @discardableResult public func updateAgentWindowStatus(
        workspaceID: String, provider: AgentProvider, terminalTrackingID: String? = nil, codexThreadID: String? = nil,
        terminalNativeID: String? = nil, yabaiWindowID: Int? = nil, label: String? = nil, status: AgentWindowStatus,
        claimedLauncherName: String? = nil, eventType: String? = nil, eventSource: String = "orchestrator", environmentKeys: [String]? = nil
    ) throws -> AgentWindowRecord {
        let now = nowISO8601()
        let allAgentWindows = try store.agentWindows(workspaceID: workspaceID)
        let trustedYabaiWindowID = trustedAgentYabaiWindowID(
            provider: provider, terminalTrackingID: terminalTrackingID, terminalNativeID: terminalNativeID, yabaiWindowID: yabaiWindowID)
        let matchedProcess = try matchedWorkspaceProcessForAgent(
            workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID, yabaiWindowID: trustedYabaiWindowID)
        let resolvedTerminalNativeID = matchedProcess?.terminalNativeID ?? terminalNativeID
        let resolvedTrustedYabaiWindowID = trustedAgentYabaiWindowID(
            provider: provider, terminalTrackingID: terminalTrackingID, terminalNativeID: resolvedTerminalNativeID, yabaiWindowID: yabaiWindowID)
        let trackedWindow = try ensureTrackedWindowExistsForAgent(
            workspaceID: workspaceID, provider: provider, label: label, terminalTrackingID: terminalTrackingID,
            terminalNativeID: resolvedTerminalNativeID, yabaiWindowID: resolvedTrustedYabaiWindowID)
        let resolvedWindowID = trackedWindow?.windowID ?? resolvedTrustedYabaiWindowID
        let finalTerminalNativeID = trackedWindow?.terminalNativeID ?? resolvedTerminalNativeID
        let existing = try matchingAgentWindow(
            workspaceID: workspaceID, terminalTrackingID: terminalTrackingID, codexThreadID: codexThreadID, yabaiWindowID: resolvedWindowID,
            label: label, provider: provider, allowLabelFallbackWithExplicitIdentity: provider == .spaces)
        if let existing {
            let resolvedClaimedLauncherName = claimedLauncherName ?? existing.claimedLauncherName
            let resolvedLabel = try uniqueAgentFocusLabel(
                workspaceID: workspaceID, preferredLabel: label ?? existing.label, excludingAgentWindowID: existing.id,
                claimedLauncherName: resolvedClaimedLauncherName)
            let updated = AgentWindowRecord(
                id: existing.id, workspaceID: existing.workspaceID, provider: existing.provider, label: resolvedLabel,
                runtimeTargetID: existing.runtimeTargetID ?? trackedWindow?.id,
                terminalTarget: TerminalTargetRecord(
                    runtimeTargetID: existing.runtimeTargetID ?? trackedWindow?.id,
                    windowID: resolvedWindowID
                        ?? (ignoresUntrustedSpacesAgentYabaiWindowID(
                            provider: provider, terminalTrackingID: terminalTrackingID, terminalNativeID: finalTerminalNativeID)
                            ? nil : existing.windowID),
                    trackingID: terminalTrackingID ?? finalTerminalNativeID ?? existing.terminalTrackingID),
                sessionKey: codexThreadID ?? existing.codexThreadID, claimedLauncherID: existing.claimedLauncherID,
                claimedLauncherName: resolvedClaimedLauncherName, status: status, createdAt: existing.createdAt, updatedAt: now)
            try validateWorkspaceFocusNames(
                workspaceID: workspaceID, processes: try store.workspaceProcesses(workspaceID: workspaceID),
                browserSessions: try store.workspaceBrowserSessions(workspaceID: workspaceID),
                agentWindows: allAgentWindows.map { $0.id == existing.id ? updated : $0 })
            try store.upsertAgentWindow(updated)
            appendAgentSessionEvent(
                agentSessionID: updated.id, eventType: eventType ?? status.rawValue, source: eventSource,
                message: agentSessionEventMessage(
                    provider: updated.provider, label: updated.label, terminalTrackingID: updated.terminalTrackingID,
                    terminalNativeID: updated.terminalNativeID, codexThreadID: updated.codexThreadID, yabaiWindowID: updated.yabaiWindowID,
                    environmentKeys: environmentKeys), createdAt: now)
            return updated
        }
        return try registerAgentWindow(
            workspaceID: workspaceID, provider: provider, label: label, terminalTrackingID: terminalTrackingID,
            terminalNativeID: resolvedTerminalNativeID, codexThreadID: codexThreadID, yabaiWindowID: resolvedTrustedYabaiWindowID, status: status,
            claimedLauncherName: claimedLauncherName, eventType: eventType ?? status.rawValue, eventSource: eventSource,
            environmentKeys: environmentKeys)
    }

    @discardableResult public func handleAgentExit(
        workspaceID: String, provider: AgentProvider, terminalTrackingID: String? = nil, codexThreadID: String? = nil,
        terminalNativeID: String? = nil, yabaiWindowID: Int? = nil, label: String? = nil, eventType: String = "exit",
        eventSource: String = "orchestrator", environmentKeys: [String]? = nil
    ) throws -> AgentWindowRecord? {
        guard
            let existing = try matchingAgentWindow(
                workspaceID: workspaceID, terminalTrackingID: terminalTrackingID, codexThreadID: codexThreadID, yabaiWindowID: yabaiWindowID,
                label: label, provider: provider)
        else { return nil }
        let resolvedWindowID =
            try matchedTrackedWindowForAgent(
                workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID ?? existing.terminalTrackingID,
                yabaiWindowID: yabaiWindowID ?? existing.yabaiWindowID ?? existing.windowID)?.windowID ?? yabaiWindowID ?? existing.yabaiWindowID
            ?? existing.windowID
        if try spacesAgentRecordIsConfiguredLauncher(workspaceID: workspaceID, record: existing, fallbackLabel: label) {
            return try updateAgentWindowStatus(
                workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID ?? existing.terminalTrackingID,
                codexThreadID: codexThreadID ?? existing.codexThreadID, terminalNativeID: terminalNativeID ?? existing.terminalNativeID,
                yabaiWindowID: resolvedWindowID, label: label ?? existing.label, status: .done, claimedLauncherName: existing.claimedLauncherName,
                eventType: eventType, eventSource: eventSource, environmentKeys: environmentKeys)
        }
        if agentWindowIsOpen(resolvedWindowID) {
            return try updateAgentWindowStatus(
                workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID ?? existing.terminalTrackingID,
                codexThreadID: codexThreadID ?? existing.codexThreadID, terminalNativeID: terminalNativeID ?? existing.terminalNativeID,
                yabaiWindowID: resolvedWindowID, label: label ?? existing.label, status: .idle, eventType: eventType, eventSource: eventSource,
                environmentKeys: environmentKeys)
        }
        appendAgentSessionEvent(
            agentSessionID: existing.id, eventType: eventType, source: eventSource,
            message: agentSessionEventMessage(
                provider: existing.provider, label: label ?? existing.label, terminalTrackingID: terminalTrackingID ?? existing.terminalTrackingID,
                terminalNativeID: terminalNativeID ?? existing.terminalNativeID, codexThreadID: codexThreadID ?? existing.codexThreadID,
                yabaiWindowID: resolvedWindowID, environmentKeys: environmentKeys), createdAt: nowISO8601())
        terminateBuiltInTerminalSession(existing.terminalNativeID ?? existing.terminalTrackingID)
        try store.deleteAgentWindow(id: existing.id)
        try removeAdHocTrackedWindowForAgent(
            workspaceID: workspaceID, provider: provider, terminalTrackingID: terminalTrackingID ?? existing.terminalTrackingID,
            yabaiWindowID: resolvedWindowID)
        return nil
    }

    public func focusAgentWindow(_ record: AgentWindowRecord) throws {
        let focused = try focusAgentWindowOrLaunchClaimedLauncher(record, requestID: nil)
        guard focused else { throw missingTrackedAgentError(record) }
        rememberNavigationTarget(.agent(record), workspaceID: record.workspaceID)
        try markWorkspaceRunningIfNeeded(workspaceID: record.workspaceID)
        try setActiveWorkspace(id: record.workspaceID)
    }

    public func stopCodingAgent(workspaceID: String, agentID: String) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            guard let record = try store.agentWindows(workspaceID: workspaceID).first(where: { $0.id == agentID }) else { return }
            try stopCodingAgentRecord(record)
            try clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: workspaceID)
        }
    }

    @discardableResult public func restartCodingAgent(workspaceID: String, agentID: String) throws -> AgentWindowRecord {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            try requireWorkspaceSetupSucceeded(workspaceID: workspaceID)
            guard let record = try store.agentWindows(workspaceID: workspaceID).first(where: { $0.id == agentID }) else {
                throw WorkspaceError.invalidArgument(message: "Coding agent is not running.")
            }
            let launcher = try restartableCodingAgentLauncher(record)
            try stopCodingAgentRecord(record)
            return try launchAgentLauncher(workspaceID: workspaceID, launcherID: launcher.id)
        }
    }

    private func stopCodingAgentRecord(_ record: AgentWindowRecord) throws {
        let windowID = try trackedAgentWindowID(record) ?? record.yabaiWindowID ?? record.windowID
        if let sessionID = record.terminalNativeID ?? record.terminalTrackingID, !sessionID.isEmpty { terminateBuiltInTerminalSession(sessionID) }
        appendAgentSessionEvent(
            agentSessionID: record.id, eventType: "stop", source: "orchestrator",
            message: agentSessionEventMessage(
                provider: record.provider, label: record.label, terminalTrackingID: record.terminalTrackingID,
                terminalNativeID: record.terminalNativeID, codexThreadID: record.codexThreadID, yabaiWindowID: windowID), createdAt: nowISO8601())
        try store.deleteAgentWindow(id: record.id)
        try removeAdHocTrackedWindowForAgent(
            workspaceID: record.workspaceID, provider: record.provider, terminalTrackingID: record.terminalTrackingID,
            yabaiWindowID: record.yabaiWindowID ?? record.windowID)
    }

    private func restartableCodingAgentLauncher(_ record: AgentWindowRecord) throws -> AgentLauncher {
        let launchers = try store.workspaceAgentLaunchers(workspaceID: record.workspaceID)
        if let claimedLauncherID = record.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines), !claimedLauncherID.isEmpty {
            guard let launcher = launchers.first(where: { $0.id == claimedLauncherID }) else {
                throw WorkspaceError.invalidArgument(message: "Configured coding agent not found.")
            }
            return launcher
        }
        if let claimedLauncherName = record.claimedLauncherName?.trimmingCharacters(in: .whitespacesAndNewlines), !claimedLauncherName.isEmpty {
            guard let launcher = launchers.first(where: { normalizedFocusName($0.name) == normalizedFocusName(claimedLauncherName) }) else {
                throw WorkspaceError.invalidArgument(message: "Configured coding agent not found.")
            }
            return launcher
        }
        if let label = record.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
            let launcher = launchers.first(where: { normalizedFocusName($0.name) == normalizedFocusName(label) })
        {
            return launcher
        }
        throw WorkspaceError.invalidArgument(message: "Unconfigured live coding agents cannot be restarted from Spaces.")
    }

    private func terminateBuiltInTerminalSession(_ sessionID: String?) {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty else { return }
        builtInTerminalWindowCloser(sessionID)
        builtInTerminalSessionTerminator(sessionID)
    }

    private func terminateBuiltInTerminalSessionsForConfiguredProcesses(workspaceID: String) throws {
        for process in try store.runningProcesses(workspaceID: workspaceID) { terminateBuiltInTerminalSession(for: process) }
    }

    private func builtInTerminalSessionID(for process: RunningProcessRecord) -> String? {
        guard terminalHost(for: process.terminalApp) == .spaces else { return nil }
        return normalizedTerminalSessionID(process.terminalNativeID ?? process.terminalTrackingID)
    }

    private func builtInTerminalSessionID(for agent: AgentWindowRecord) -> String? {
        guard agent.provider == .spaces else { return nil }
        return normalizedTerminalSessionID(agent.terminalNativeID ?? agent.terminalTrackingID)
    }

    private func terminalSessionID(for window: WindowRecord) -> String? {
        normalizedTerminalSessionID(window.terminalNativeID ?? window.terminalTrackingID)
    }

    private func normalizedTerminalSessionID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func workspaceForBuiltInTerminalSession(sessionID: String, ownership existingOwnership: BuiltInTerminalSessionOwnership? = nil) throws
        -> WorkspaceRecord?
    {
        let ownership = try existingOwnership ?? builtInTerminalSessionOwnership(sessionID: sessionID)
        if let workspaceID = ownership.processWorkspaceID ?? ownership.agentWorkspaceID ?? ownership.terminalWindowWorkspaceID
            ?? ownership.launchWorkspaceID
        {
            return try store.workspace(id: workspaceID)
        }
        guard let workingDirectory = terminalSessionWorkingDirectory(sessionID: sessionID) else { return nil }
        let workspaces = try store.projects().flatMap { project in try store.workspaces(projectID: project.id, includeArchived: false) }
        return workspaces.filter { isPath(workingDirectory, inside: $0.dir, allowEqual: true) }.max {
            normalizePath($0.dir).count < normalizePath($1.dir).count
        }
    }

    private func terminalSession(sessionID: String, belongsTo workspace: WorkspaceRecord) -> Bool {
        guard let workingDirectory = terminalSessionWorkingDirectory(sessionID: sessionID) else { return false }
        return isPath(workingDirectory, inside: workspace.dir, allowEqual: true)
    }

    private func terminalSessionWorkingDirectory(sessionID: String) -> String? {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths),
            launchConfiguration.backend == .ghosttyEmbedded
        else { return nil }
        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        return runtimeState?.workingDirectory ?? launchConfiguration.workingDirectory
    }

    private func builtInTerminalSessionOwnership(sessionID: String) throws -> BuiltInTerminalSessionOwnership {
        let workspaces = try store.projects().flatMap { project in try store.workspaces(projectID: project.id, includeArchived: true) }
        var owningProcess: RunningProcessRecord?
        var owningAgent: AgentWindowRecord?
        var terminalWindowWorkspaceID: String?
        for workspace in workspaces {
            if owningProcess == nil {
                owningProcess = try store.runningProcesses(workspaceID: workspace.id).first { builtInTerminalSessionID(for: $0) == sessionID }
            }
            if owningAgent == nil {
                owningAgent = try store.agentWindows(workspaceID: workspace.id).first { builtInTerminalSessionID(for: $0) == sessionID }
            }
            if terminalWindowWorkspaceID == nil,
                try store.windows(workspaceID: workspace.id).contains(where: {
                    $0.role == "terminal" && terminalHost(for: $0.app) == .spaces && terminalSessionID(for: $0) == sessionID
                })
            {
                terminalWindowWorkspaceID = workspace.id
            }
            if owningProcess != nil, owningAgent != nil, terminalWindowWorkspaceID != nil { break }
        }
        let launchConfiguration = terminalSessionLaunchConfiguration(sessionID: sessionID)
        return BuiltInTerminalSessionOwnership(
            process: owningProcess, agent: owningAgent, terminalWindowWorkspaceID: terminalWindowWorkspaceID,
            launchWorkspaceID: launchConfiguration?.workspaceID, launchKind: launchConfiguration?.kind)
    }

    private func builtInTerminalSessionHasConfiguredOwner(_ ownership: BuiltInTerminalSessionOwnership) -> Bool {
        if ownership.process != nil { return true }
        switch ownership.launchKind {
        case .process, .agent: return true
        case .shell: return false
        case nil: return ownership.agent != nil
        }
    }

    private func terminalSessionLaunchConfiguration(sessionID: String) -> TerminalSessionLaunchConfiguration? {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths),
            launchConfiguration.backend == .ghosttyEmbedded
        else { return nil }
        return launchConfiguration
    }

    private func terminateBuiltInTerminalSession(for process: RunningProcessRecord) {
        terminateBuiltInTerminalSession(builtInTerminalSessionID(for: process))
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

    public func recoverMissingConfiguredProcess(workspaceID: String, processKey: String, processTemplateID: String? = nil) throws {
        try requireWorkspaceSetupSucceeded(workspaceID: workspaceID)
        let recoverStartedAt = currentDate()
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        let trimmedTemplateID = processTemplateID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let template: ProcessTemplate? =
            if !trimmedTemplateID.isEmpty { (settings?.processes ?? []).first(where: { $0.id == trimmedTemplateID }) } else {
                (settings?.processes ?? []).first(where: { configuredProcessMatchesKey($0, key: processKey) })
            }
        guard let template else { throw WorkspaceError.invalidArgument(message: "Configured process not found.") }

        let running = try store.runningProcesses(workspaceID: workspaceID)
        let expectedKey = configuredProcessMatchKey(name: template.name)
        if let existing = running.first(where: { runningProcessMatchesTemplate($0, template: template, fallbackKey: expectedKey) }) {
            if existing.status == .exited {
                try restartProcessInTerminal(
                    workspaceID: workspaceID, process: existing, templateOverride: template, terminalHostOverride: try configuredTerminalHost())
            }
            try markWorkspaceRunningIfNeeded(workspace)
            return
        }

        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        let terminalHost = try configuredTerminalHost()
        _ = try launchConfiguredProcess(template: template, workspace: workspace, env: env, terminalHost: terminalHost)
        try markWorkspaceRunningIfNeeded(workspace)
        logPerfMetric(
            "process_recover", workspaceID: workspaceID, target: configuredProcessMatchKey(name: template.name),
            detail: "host=\(terminalHost.rawValue)", elapsedMS: elapsedMS(since: recoverStartedAt), success: true)
    }

    public func runConfiguredProcess(workspaceID: String, processKey: String) throws {
        try recoverMissingConfiguredProcess(workspaceID: workspaceID, processKey: processKey)
    }

    public func runConfiguredProcess(workspaceID: String, processTemplateID: String, processKey: String) throws {
        try recoverMissingConfiguredProcess(workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID)
    }

    @discardableResult public func launchAgentLauncher(workspaceID: String, name: String, background: Bool = false) throws -> AgentWindowRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw WorkspaceError.invalidArgument(message: "Coding agent name is required.") }
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        guard let launcher = settings?.agentLaunchers.first(where: { normalizedFocusName($0.name) == normalizedFocusName(trimmedName) }) else {
            throw WorkspaceError.invalidArgument(message: "Configured coding agent not found.")
        }
        return try launchAgentLauncher(launcher, project: project, workspace: workspace, background: background)
    }

    @discardableResult public func launchAgentLauncher(workspaceID: String, launcherID: String, background: Bool = false) throws -> AgentWindowRecord
    {
        let trimmedID = launcherID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { throw WorkspaceError.invalidArgument(message: "Coding agent ID is required.") }
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        guard let launcher = settings?.agentLaunchers.first(where: { $0.id == trimmedID }) else {
            throw WorkspaceError.invalidArgument(message: "Configured coding agent not found.")
        }
        return try launchAgentLauncher(launcher, project: project, workspace: workspace, background: background)
    }

    @discardableResult private func launchAgentLauncher(
        _ launcher: AgentLauncher, project: ProjectRecord, workspace: WorkspaceRecord, background: Bool
    ) throws -> AgentWindowRecord {
        let workspaceID = workspace.id
        try requireWorkspaceSetupSucceeded(workspaceID: workspaceID)
        if let existing = try store.agentWindows(workspaceID: workspaceID).first(where: {
            if $0.claimedLauncherID == launcher.id { return true }
            guard $0.claimedLauncherID == nil else { return false }
            return normalizedFocusName($0.label ?? $0.claimedLauncherName ?? "") == normalizedFocusName(launcher.name)
        }) {
            if existing.provider == .spaces, !builtInAgentSessionIsStillLive(existing) {
                try removeStaleAgentWindow(existing)
            } else {
                if try focusAgentWindowRecord(existing, requestID: nil) {
                    try markWorkspaceRunningIfNeeded(workspace)
                    return existing
                }
                let existingWindowID = try trackedAgentWindowID(existing) ?? existing.yabaiWindowID ?? existing.windowID
                // A failed focus attempt is not enough evidence to destroy the reserved row.
                // Only evict the existing record when its terminal is actually gone; otherwise
                // keep the current slot and treat launch as an idempotent no-op.
                if agentWindowIsOpen(existingWindowID) {
                    try markWorkspaceRunningIfNeeded(workspace)
                    return existing
                }
                try removeStaleAgentWindow(existing)
            }
        }

        let terminalHost = try configuredTerminalHost()
        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        var launchEnv = terminalLaunchEnvironment(
            base: env.merging([Self.agentLabelEnvVar: launcher.name]) { _, new in new }, terminalHost: terminalHost, includeInheritedPath: false)
        _ = background
        let agentSessionID = UUID().uuidString
        launchEnv[Self.terminalTrackingIDEnvVar] = agentSessionID
        let sessionCommand = commandPrefixedWithShellEnvironment(
            wrappedAgentLauncherCommand(
                name: launcher.name, command: applyEnvVars(launcher.command, env: env), shellPath: terminalShellPathOverride()), env: launchEnv)
        let session = try launchSpacesTerminalSession(
            title: launcher.name, workingDirectory: workspace.dir, command: sessionCommand, showMode: .owner, backend: .ghosttyEmbedded,
            readinessPolicy: .sessionReady, sessionID: agentSessionID, workspaceID: workspace.id, kind: .agent)
        let record = try registerAgentWindow(
            workspaceID: workspace.id, provider: agentProvider(for: terminalHost), label: launcher.name, terminalTrackingID: session.sessionID,
            terminalNativeID: session.sessionID, yabaiWindowID: session.windowID, status: .idle, claimedLauncherID: launcher.id,
            claimedLauncherName: launcher.name)
        try markWorkspaceRunningIfNeeded(workspace)
        return record
    }

    private func configuredProcessMatchesKey(_ template: ProcessTemplate, key: String) -> Bool {
        let trimmedName = template.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmedName.isEmpty && trimmedName == key
    }

    private func runningProcessMatchesTemplate(_ process: RunningProcessRecord, template: ProcessTemplate, fallbackKey: String) -> Bool {
        if let templateID = process.templateID?.trimmingCharacters(in: .whitespacesAndNewlines), !templateID.isEmpty {
            return templateID == template.id
        }
        return !fallbackKey.isEmpty && runningProcessMatchKey(name: process.templateName) == fallbackKey
    }

    private func wrappedAgentLauncherCommand(name: String, command: String, shellPath: String?) -> String {
        let escapedName = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "'\\''")
        let wrappedCommand = "printf '\\033]0;\(escapedName)\\007'; \(command)"
        let resolvedShell: String
        if let trimmedShell = shellPath?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedShell.isEmpty {
            resolvedShell = trimmedShell
        } else {
            resolvedShell = "/bin/zsh"
        }
        return "exec \(shellQuoted(resolvedShell)) -ilc \(shellQuoted(wrappedCommand))"
    }

    public func recoverRunningWorkspaceProcessIfPossible(workspaceID: String, processID: String) throws -> Bool {
        try requireWorkspaceSetupSucceeded(workspaceID: workspaceID)
        guard let process = try store.runningProcesses(workspaceID: workspaceID).first(where: { $0.id == processID }) else { return false }
        return try recoverRunningProcessTerminalIfPossible(workspaceID: workspaceID, process: process)
    }

    public func recoverMissingBrowserSession(workspaceID: String, targetURL: String) throws {
        try requireWorkspaceSetupSucceeded(workspaceID: workspaceID)
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let sessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        guard !sessions.isEmpty else { throw WorkspaceError.invalidArgument(message: "No browser sessions are configured for this workspace.") }
        guard chrome.isAvailable() else { throw WorkspaceError.dependencyMissing(message: "Google Chrome is required for browser sessions.") }

        let namedPorts = try store.workspacePortsNamed(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: namedPorts)
        let resolvedSessions = resolveBrowserSessions(sessions, env: env)
        guard
            let matchedSession = resolvedSessions.compactMap({ resolved -> (session: ResolvedBrowserSession, score: Int)? in
                guard let score = browserURLMatchScore(targetURL, targetURL: resolved.prefix) else { return nil }
                return (resolved, score)
            }).max(by: { lhs, rhs in
                if lhs.score == rhs.score { return lhs.session.prefix.count < rhs.session.prefix.count }
                return lhs.score < rhs.score
            })?.session
        else { throw WorkspaceError.invalidArgument(message: "Browser session not found for recovery.") }

        let snapshot = bestEffortYabaiWindowSnapshot()
        _ = try chrome.openWindow(url: matchedSession.prefix, background: false)
        guard let newWindow = try captureNewAppWindow(snapshot: snapshot, appName: "Google Chrome") else {
            throw WorkspaceError.invalidArgument(message: "Failed to recover browser session window.")
        }

        var updatedSessions = sessions
        updatedSessions[matchedSession.index].extractedWindow = ExtractedBrowserWindowMapping(
            targetURL: matchedSession.prefix, windowID: newWindow.id, isValid: true)
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: updatedSessions)

        let trackedWindows = try store.windows(workspaceID: workspace.id)
        let existingWindow = trackedWindows.first(where: { window in
            guard window.role == "browser", let trackedTargetURL = window.targetURL else { return false }
            return browserURLMatchesTarget(matchedSession.prefix, targetURL: trackedTargetURL)
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
        let closedManagedTerminalWindowID: Int?
        if isManagedTerminalApp(process.terminalApp) {
            terminateBuiltInTerminalSession(for: process)
            closedManagedTerminalWindowID = process.windowID
            if let pid = resolvedRuntimePID(for: process) { terminateProcessGroup(pid: pid) }
        } else {
            closedManagedTerminalWindowID = nil
            if let pid = resolvedRuntimePID(for: process) { terminateProcessGroup(pid: pid) }
        }
        if let terminalWindow = try store.windows(workspaceID: workspaceID).first(where: { matchesTrackedTerminalWindow($0, process: process) }) {
            if terminalWindow.role == "terminal", isManagedTerminalApp(terminalWindow.app) {
                if terminalWindow.windowID != closedManagedTerminalWindowID,
                    let sessionID = normalizedTerminalSessionID(terminalWindow.terminalNativeID ?? terminalWindow.terminalTrackingID)
                {
                    builtInTerminalWindowCloser(sessionID)
                }
            } else if let windowID = terminalWindow.windowID {
                _ = try? yabai.closeWindow(id: windowID)
            }
            try store.deleteWindow(id: terminalWindow.id)
        }

        try store.deleteRunningProcess(id: process.id)

        try clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: workspaceID)
    }

    private func clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: String) throws {
        guard try !hasTrackedRuntimeIndicators(workspaceID: workspaceID), let workspace = try store.workspace(id: workspaceID) else { return }
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: false, launchedAt: workspace.lastLaunchedAt)
    }

    private func recoverRunningProcessTerminalIfPossible(workspaceID: String, process: RunningProcessRecord) throws -> Bool {
        try requireWorkspaceSetupSucceeded(workspaceID: workspaceID)
        guard let terminalHost = terminalHost(for: process.terminalApp) else { return false }
        if terminalHost == .spaces {
            let sessionID = process.terminalNativeID ?? process.terminalTrackingID
            guard let sessionID, !sessionID.isEmpty else { return false }
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else { return false }
            guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { return false }
            guard runtimeState.state == .starting || runtimeState.state == .running else { return false }
            guard let pid = resolvedRuntimePID(for: process), isProcessAlive(pid: pid) else { return false }
            let (_, workspace) = try resolveWorkspace(id: workspaceID)
            let snapshot = bestEffortYabaiWindowSnapshot()
            builtInTerminalWindowOpener(sessionID, .owner)
            let capturedWindowID = bestEffortCaptureNewAppWindowID(snapshot: snapshot, appName: terminalAppName(for: terminalHost))
            let now = nowISO8601()
            try store.upsert(
                runningProcess: RunningProcessRecord(
                    id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                    terminalApp: process.terminalApp, windowID: capturedWindowID, terminalTrackingID: sessionID, terminalNativeID: sessionID,
                    terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: pid, status: .running,
                    logPath: process.logPath ?? paths.outputPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: nil))

            let existingWindow = try store.windows(workspaceID: workspace.id).first(where: { window in
                window.role == "terminal"
                    && (window.id == process.id || window.windowID == process.windowID || window.terminalTrackingID == sessionID)
            })
            try store.upsert(
                window: WindowRecord(
                    id: existingWindow?.id ?? process.id, workspaceID: workspace.id, app: terminalAppName(for: terminalHost),
                    name: process.templateName, detail: process.command, targetURL: nil, windowID: capturedWindowID, terminalTrackingID: sessionID,
                    terminalNativeID: sessionID, terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal",
                    orderIndex: existingWindow?.orderIndex
                        ?? Self.nextWindowOrderIndex(existing: try store.windows(workspaceID: workspace.id), role: "terminal", orderOffset: 200),
                    lastSeenAt: now))
            return true
        }
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
        let terminalContainerID = storedTerminalContainerID(terminalHost: terminalHost, handle: terminalHandle)
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                runtimeTargetID: process.runtimeTargetID, terminalApp: process.terminalApp, windowID: capturedWindowID,
                terminalTrackingID: hookSessionID, terminalNativeID: terminalNativeID, terminalContainerID: terminalContainerID, itermTabIndex: nil,
                tmuxWindowID: process.tmuxWindowID, pid: pid, status: .running, logPath: process.logPath, lastOutputAt: process.lastOutputAt,
                startedAt: process.startedAt, exitedAt: nil))

        let existingWindow = try store.windows(workspaceID: workspace.id).first(where: { window in
            window.role == "terminal"
                && (window.id == process.id || window.windowID == process.windowID || window.tmuxWindowID == process.tmuxWindowID)
        })
        try store.upsert(
            window: WindowRecord(
                id: existingWindow?.id ?? process.id, workspaceID: workspace.id, app: terminalAppName(for: terminalHost), name: process.templateName,
                detail: process.command, targetURL: nil, windowID: capturedWindowID, terminalTrackingID: hookSessionID,
                terminalNativeID: terminalNativeID, terminalContainerID: terminalContainerID, itermTabIndex: nil, tmuxWindowID: process.tmuxWindowID,
                role: "terminal",
                orderIndex: existingWindow?.orderIndex
                    ?? Self.nextWindowOrderIndex(existing: try store.windows(workspaceID: workspace.id), role: "terminal", orderOffset: 200),
                lastSeenAt: now))
        return true
    }

    @discardableResult private func launchConfiguredProcess(
        template: ProcessTemplate, workspace: WorkspaceRecord, env: [String: String], terminalHost: TerminalHost, background: Bool = false
    ) throws -> RunningProcessRecord {
        try requireWorkspaceSetupSucceeded(workspaceID: workspace.id)
        if terminalHost == .spaces {
            let name = processKey(for: template)
            let sessionCommand = try spacesTerminalCommand(template: template, env: env)
            let session = try launchSpacesTerminalSession(
                title: name, workingDirectory: workspace.dir, command: sessionCommand, showMode: .owner, backend: .ghosttyEmbedded,
                readinessPolicy: .sessionReady, workspaceID: workspace.id, kind: .process)
            let now = nowISO8601()
            let record = RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateID: template.id, templateName: name, command: template.command,
                terminalApp: terminalAppName(for: terminalHost), windowID: session.windowID, terminalTrackingID: session.sessionID,
                terminalNativeID: session.sessionID, terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, pid: session.childPID,
                status: .running, logPath: session.outputPath, lastOutputAt: nil, startedAt: now, exitedAt: nil)
            try store.upsert(runningProcess: record)
            let nextOrder = Self.nextWindowOrderIndex(existing: try store.windows(workspaceID: workspace.id), role: "terminal", orderOffset: 200)
            try store.upsert(
                window: WindowRecord(
                    id: UUID().uuidString, workspaceID: workspace.id, app: terminalAppName(for: terminalHost), name: name, detail: template.command,
                    targetURL: nil, windowID: session.windowID, terminalTrackingID: session.sessionID, terminalNativeID: session.sessionID,
                    terminalContainerID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: nextOrder, lastSeenAt: now))
            return record
        }
        let name = processKey(for: template)
        let command = try processLaunchCommand(template: template)
        let snapshot = try yabai.listWindows()
        let terminalHandle = try launchProcessInTmux(
            workspace: workspace, processName: name, rawCommand: template.command, command: command, env: env, terminalHost: terminalHost,
            background: background, replaceExistingSession: true)
        let capturedWindowID =
            bestEffortCaptureNewAppWindowID(snapshot: snapshot, appName: terminalAppName(for: terminalHost)) ?? terminalHandle.fallbackWindowID
        let tmuxWindow = try currentTmuxWindowInfo(workspaceID: workspace.id, processName: name)
        let hookSessionID = storedTerminalHookSessionID(terminalHost: terminalHost, handle: terminalHandle)
        let terminalNativeID = storedTerminalNativeID(terminalHost: terminalHost, handle: terminalHandle)
        let terminalContainerID = storedTerminalContainerID(terminalHost: terminalHost, handle: terminalHandle)
        let record = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateID: template.id, templateName: name, command: template.command,
            terminalApp: terminalAppName(for: terminalHost), windowID: capturedWindowID, terminalTrackingID: hookSessionID,
            terminalNativeID: terminalNativeID, terminalContainerID: terminalContainerID, itermTabIndex: nil, tmuxWindowID: tmuxWindow?.id,
            pid: tmuxWindow?.panePID, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nowISO8601(), exitedAt: nil)
        try store.upsert(runningProcess: record)
        let nextOrder = Self.nextWindowOrderIndex(existing: try store.windows(workspaceID: workspace.id), role: "terminal", orderOffset: 200)
        try store.upsert(
            window: WindowRecord(
                id: record.id, workspaceID: workspace.id, app: terminalAppName(for: terminalHost), name: name, detail: template.command,
                targetURL: nil, windowID: capturedWindowID, terminalTrackingID: hookSessionID, terminalNativeID: terminalNativeID,
                terminalContainerID: terminalContainerID, itermTabIndex: nil, tmuxWindowID: tmuxWindow?.id, role: "terminal", orderIndex: nextOrder,
                lastSeenAt: nowISO8601()))
        return record
    }

    private func focusWorkspaceProcessRecord(_ process: RunningProcessRecord, workspaceID: String) throws -> Bool {
        try focusWorkspaceProcessOutcome(process, workspaceID: workspaceID, requestID: nil).focused
    }

    private func focusWorkspaceProcessOutcome(_ process: RunningProcessRecord, workspaceID: String, requestID: String?) throws
        -> WorkspaceProcessFocusOutcome
    {
        guard isManagedTerminalApp(process.terminalApp) else {
            return WorkspaceProcessFocusOutcome(focused: false, route: "unavailable", focusedExistingWindow: false)
        }
        let target = try resolvedProcessTerminalFocusTarget(process, workspaceID: workspaceID)
        let focusResult = focusManagedTerminal(
            terminalApp: process.terminalApp, providerIdentity: target.providerIdentity, windowID: target.windowID, requestID: requestID)
        let focused: Bool
        let focusedExistingWindow: Bool
        let route: String
        switch focusResult {
        case .existingWindow:
            focused = true
            focusedExistingWindow = true
            route = "existing_window"
        case .trackedTerminal:
            focused = true
            focusedExistingWindow = target.windowID != nil
            route = "tracked_terminal"
        case .sessionRequest:
            focused = true
            focusedExistingWindow = false
            route = "session_request"
        case .reboundSession(let capturedWindowID):
            focused = true
            focusedExistingWindow = false
            route = "rebound_session"
            if terminalHost(for: process.terminalApp) == .spaces {
                if let capturedWindowID {
                    try persistBuiltInTerminalWindowBinding(process, workspaceID: workspaceID, windowID: capturedWindowID)
                } else {
                    try clearStaleBuiltInTerminalWindowBinding(process, workspaceID: workspaceID)
                }
            }
        case .reopenedSession(let capturedWindowID):
            focused = true
            focusedExistingWindow = false
            route = "reopened_session"
            if terminalHost(for: process.terminalApp) == .spaces {
                if let capturedWindowID {
                    try persistBuiltInTerminalWindowBinding(process, workspaceID: workspaceID, windowID: capturedWindowID)
                } else {
                    try clearStaleBuiltInTerminalWindowBinding(process, workspaceID: workspaceID)
                }
            }
        case .unavailable:
            if let trackedWindowID = target.windowID {
                let fallbackFocused = ((try? yabai.focusWindow(id: trackedWindowID)) ?? false)
                focused = fallbackFocused
                focusedExistingWindow = fallbackFocused
                route = fallbackFocused ? "fallback_window" : "unavailable"
            } else {
                focused = false
                focusedExistingWindow = false
                route = "unavailable"
            }
        }
        if focused, focusedExistingWindow, let trackedWindowID = target.windowID { pulseTerminalWindowIfNeeded(windowID: trackedWindowID) }
        return WorkspaceProcessFocusOutcome(focused: focused, route: route, focusedExistingWindow: focusedExistingWindow)
    }

    private func resolvedProcessTerminalFocusTarget(_ process: RunningProcessRecord, workspaceID: String) throws -> TerminalFocusTarget {
        let windows = try store.windows(workspaceID: workspaceID)
        let trackedWindow = windows.first(where: { matchesTrackedTerminalWindow($0, process: process) })
        let trackedSessionIdentity = trackedWindow?.terminalFocusIdentity
        let processSessionIdentity = process.terminalFocusIdentity
        let providerIdentity =
            trackedSessionIdentity ?? processSessionIdentity ?? trackedWindow?.windowID.map(TerminalTrackingIdentity.window)
            ?? process.windowID.map(TerminalTrackingIdentity.window)
        return TerminalFocusTarget(providerIdentity: providerIdentity, windowID: trackedWindow?.windowID ?? process.windowID)
    }

    private func clearStaleBuiltInTerminalWindowBinding(_ process: RunningProcessRecord, workspaceID: String) throws {
        let clearedProcess = RunningProcessRecord(
            id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
            terminalApp: process.terminalApp, windowID: nil, terminalTrackingID: process.terminalTrackingID,
            terminalNativeID: process.terminalNativeID, terminalContainerID: process.terminalContainerID, pid: process.pid, status: process.status,
            logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: process.exitedAt)
        try store.upsert(runningProcess: clearedProcess)
        if let trackedWindow = try store.windows(workspaceID: workspaceID).first(where: { matchesTrackedTerminalWindow($0, process: process) }) {
            try clearStaleBuiltInTerminalWindowBinding(trackedWindow)
        }
    }

    private func clearStaleBuiltInTerminalWindowBinding(_ agent: AgentWindowRecord) throws {
        guard agent.provider == .spaces else { return }
        let clearedAgent = AgentWindowRecord(
            id: agent.id, workspaceID: agent.workspaceID, provider: agent.provider, label: agent.label, runtimeTargetID: agent.runtimeTargetID,
            terminalTarget: agent.terminalTrackingID.map {
                TerminalTargetRecord(runtimeTargetID: agent.runtimeTargetID, windowID: nil, trackingID: $0)
            }, sessionKey: agent.sessionKey, claimedLauncherID: agent.claimedLauncherID, claimedLauncherName: agent.claimedLauncherName,
            status: agent.status, createdAt: agent.createdAt, updatedAt: nowISO8601())
        try store.upsertAgentWindow(clearedAgent)
    }

    private func persistBuiltInTerminalWindowBinding(_ process: RunningProcessRecord, workspaceID: String, windowID: Int) throws {
        let reboundProcess = RunningProcessRecord(
            id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
            terminalApp: process.terminalApp, windowID: windowID, terminalTrackingID: process.terminalTrackingID,
            terminalNativeID: process.terminalNativeID, terminalContainerID: process.terminalContainerID, pid: process.pid, status: process.status,
            logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: process.exitedAt)
        try store.upsert(runningProcess: reboundProcess)
        if let trackedWindow = try store.windows(workspaceID: workspaceID).first(where: { matchesTrackedTerminalWindow($0, process: process) }) {
            try persistBuiltInTerminalWindowBinding(trackedWindow, windowID: windowID)
        }
    }

    private func persistBuiltInTerminalWindowBinding(_ agent: AgentWindowRecord, windowID: Int) throws {
        guard agent.provider == .spaces else { return }
        let reboundAgent = AgentWindowRecord(
            id: agent.id, workspaceID: agent.workspaceID, provider: agent.provider, label: agent.label, runtimeTargetID: agent.runtimeTargetID,
            terminalTarget: agent.terminalTrackingID.map {
                TerminalTargetRecord(runtimeTargetID: agent.runtimeTargetID, windowID: windowID, trackingID: $0)
            }, sessionKey: agent.sessionKey, claimedLauncherID: agent.claimedLauncherID, claimedLauncherName: agent.claimedLauncherName,
            status: agent.status, createdAt: agent.createdAt, updatedAt: nowISO8601())
        try store.upsertAgentWindow(reboundAgent)
    }

    private func persistBuiltInTerminalWindowBinding(_ window: WindowRecord, windowID: Int) throws {
        let reboundWindow = WindowRecord(
            id: window.id, workspaceID: window.workspaceID, app: window.app, name: window.name, detail: window.detail, targetURL: window.targetURL,
            windowID: windowID, terminalTrackingID: window.terminalTrackingID, terminalNativeID: window.terminalNativeID,
            terminalContainerID: window.terminalContainerID, role: window.role, orderIndex: window.orderIndex, lastSeenAt: nowISO8601())
        try store.upsert(window: reboundWindow)
    }

    private func clearStaleBuiltInTerminalWindowBinding(_ window: WindowRecord) throws {
        let clearedWindow = WindowRecord(
            id: window.id, workspaceID: window.workspaceID, app: window.app, name: window.name, detail: window.detail, targetURL: window.targetURL,
            windowID: nil, terminalTrackingID: window.terminalTrackingID, terminalNativeID: window.terminalNativeID,
            terminalContainerID: window.terminalContainerID, role: window.role, orderIndex: window.orderIndex, lastSeenAt: nowISO8601())
        try store.upsert(window: clearedWindow)
    }

    private func matchesTrackedTerminalWindow(_ window: WindowRecord, process: RunningProcessRecord) -> Bool {
        guard window.role == "terminal", window.app == process.terminalApp else { return false }
        if window.id == process.id { return true }
        if let terminalID = process.terminalNativeID, !terminalID.isEmpty, window.terminalNativeID == terminalID { return true }
        if let containerID = process.terminalContainerID, !containerID.isEmpty, window.terminalContainerID == containerID { return true }
        if let terminalID = process.terminalTrackingID, !terminalID.isEmpty, window.terminalTrackingID == terminalID { return true }
        if let windowID = process.windowID, window.windowID == windowID { return true }
        return false
    }

    private func trackedAgentWindowID(_ record: AgentWindowRecord) throws -> Int? {
        let terminalApp = TerminalHost(rawValue: record.provider.rawValue)?.appName ?? TerminalHost.spaces.appName
        if record.provider == .spaces, let terminalID = record.terminalNativeID, !terminalID.isEmpty {
            if let windowID = try store.windows(workspaceID: record.workspaceID).first(where: {
                $0.app == terminalApp && $0.role == "terminal" && $0.terminalNativeID == terminalID
            })?.windowID {
                return windowID
            }
            // Older or partially reconciled Ghostty rows may still only carry the hook token on
            // their tracked terminal window. If native-ID lookup misses, fall back to that same
            // persisted tracking token rather than inferring from frontmost Ghostty state.
        }
        // If native-ID lookup misses, reconcile through the persisted Spaces session identity.
        guard let sessionID = record.terminalTrackingID, !sessionID.isEmpty else { return record.yabaiWindowID ?? record.windowID }
        return try store.windows(workspaceID: record.workspaceID).first(where: {
            $0.app == terminalApp && $0.role == "terminal" && $0.terminalTrackingID == sessionID
        })?.windowID
    }

    private func focusAgentWindowRecord(_ record: AgentWindowRecord, requestID: String?) throws -> Bool {
        let windowID = try trackedAgentWindowID(record) ?? record.yabaiWindowID ?? record.windowID
        let terminalApp = TerminalHost(rawValue: record.provider.rawValue)?.appName
        let focusResult = focusManagedTerminal(
            terminalApp: terminalApp, providerIdentity: record.terminalFocusIdentity, windowID: windowID, requestID: requestID)
        let focused: Bool
        let focusedExistingWindow: Bool
        switch focusResult {
        case .existingWindow:
            focused = true
            focusedExistingWindow = true
        case .trackedTerminal:
            focused = true
            focusedExistingWindow = windowID != nil
        case .sessionRequest:
            focused = true
            focusedExistingWindow = false
        case .reboundSession(let capturedWindowID):
            focused = true
            focusedExistingWindow = false
            if record.provider == .spaces {
                if let capturedWindowID {
                    try persistBuiltInTerminalWindowBinding(record, windowID: capturedWindowID)
                } else {
                    try clearStaleBuiltInTerminalWindowBinding(record)
                }
            }
        case .reopenedSession(let capturedWindowID):
            focused = true
            focusedExistingWindow = false
            if record.provider == .spaces {
                if let capturedWindowID {
                    try persistBuiltInTerminalWindowBinding(record, windowID: capturedWindowID)
                } else {
                    try clearStaleBuiltInTerminalWindowBinding(record)
                }
            }
        case .unavailable:
            if let windowID {
                let fallbackFocused = (try? yabai.focusWindow(id: windowID)) ?? false
                focused = fallbackFocused
                focusedExistingWindow = fallbackFocused
            } else {
                focused = false
                focusedExistingWindow = false
            }
        }
        if focused, focusedExistingWindow, let windowID { pulseTerminalWindowIfNeeded(windowID: windowID) }
        return focused
    }

    private func focusAgentWindowOrLaunchClaimedLauncher(_ record: AgentWindowRecord, requestID: String?) throws -> Bool {
        let claimedLauncherID = record.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let claimedLauncherName = record.claimedLauncherName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard claimedLauncherID?.isEmpty == false || claimedLauncherName?.isEmpty == false else {
            return try focusAgentWindowRecord(record, requestID: requestID)
        }
        if record.provider == .spaces, !builtInAgentSessionIsStillLive(record), builtInAgentSessionID(for: record) != nil {
            return try focusAgentWindowRecord(record, requestID: requestID)
        }
        if try focusAgentWindowRecord(record, requestID: requestID) { return true }
        if let claimedLauncherID, !claimedLauncherID.isEmpty {
            _ = try launchAgentLauncher(workspaceID: record.workspaceID, launcherID: claimedLauncherID)
        } else if let claimedLauncherName, !claimedLauncherName.isEmpty {
            _ = try launchAgentLauncher(workspaceID: record.workspaceID, name: claimedLauncherName)
        } else {
            return false
        }
        return true
    }

    private func missingTrackedWindowError(for window: WindowRecord, workspaceID: String) -> WorkspaceError {
        if window.role == "browser" {
            return .missingTrackedWindow(
                MissingTrackedWindowContext(
                    kind: .browserSession, workspaceID: workspaceID, windowID: window.windowID, targetURL: window.targetURL,
                    title: window.name ?? window.targetURL ?? "Browser Session"))
        }
        return .missingTrackedWindow(
            MissingTrackedWindowContext(kind: .window, workspaceID: workspaceID, windowID: window.windowID, title: window.name ?? window.app))
    }

    private func missingTrackedProcessError(_ process: RunningProcessRecord, workspaceID: String) -> WorkspaceError {
        .missingTrackedWindow(
            MissingTrackedWindowContext(
                kind: .process, workspaceID: workspaceID, windowID: process.windowID, processID: process.id, title: process.templateName))
    }

    private func missingTrackedAgentError(_ record: AgentWindowRecord) -> WorkspaceError {
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
