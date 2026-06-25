import Foundation
import spacesterminalcore
import systembridge

#if canImport(CryptoKit)
    import CryptoKit
#endif
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
#if canImport(UserNotifications)
    @preconcurrency import UserNotifications
#endif

public final class WorkspaceOrchestrator {
    public typealias BuiltInTerminalWindowOpener = @Sendable (String, TerminalAttachmentMode) -> Void
    public typealias BuiltInTerminalWindowFocuser = @Sendable (String, String?) -> Void
    public typealias BuiltInTerminalWindowCloser = @Sendable (String) -> Void
    public typealias BuiltInTerminalSessionTerminator = @Sendable (String) -> Void
    public typealias BuiltInTerminalSessionLauncher = @Sendable (TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary

    #if canImport(UserNotifications)
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
    #else
        private final class NotificationAuthorizationCache: @unchecked Sendable {}
    #endif

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

    public static func sendTerminalServiceRequest(to target: SpacesDaemonConnectionTarget, request: TerminalServiceRequest) throws
        -> TerminalServiceResponse
    {
        guard let socketPath = target.socketPath else { throw WorkspaceError.invalidArgument(message: "Local spacesd socket path is missing.") }
        return try TerminalServiceClient.send(request: request, socketPath: socketPath, timeout: 15)
    }

    struct ResolvedBrowserSession {
        let index: Int
        let prefix: String
        let session: BrowserSession
    }

    struct WorkspaceConfigurationSnapshot {
        let workspace: WorkspaceRecord
        let settings: WorkspaceSettings?
        let assignedPorts: [(definitionID: String, port: Int, name: String)]
    }

    struct GitProjectImportPlan {
        let gitURL: String
        let project: ProjectRecord
        let destination: URL
    }

    struct BrowserWindowScanResult {
        let windows: [WindowRecord]
        let tabIndexByWindowAndURL: [String: Int]
    }

    struct CachedScannedBrowserTabTarget {
        let tabIndex: Int
        let browserPrefixes: [String]
    }

    struct ScannedBrowserFocusTarget {
        let windowID: Int
        let tabIndex: Int
        let matchedURL: String
    }

    struct BrowserWindowScanCacheEntry {
        let browserPrefixes: [String]
        let refreshedAt: Date
        let scanResult: BrowserWindowScanResult
    }

    struct SpacesTerminalSessionHandle {
        let sessionID: String
        let childPID: Int?
        let windowID: Int?
        let outputPath: String
    }

    struct ManagedTerminalFocusTarget {
        let providerIdentity: TerminalTrackingIdentity?
        let windowID: Int?
    }

    struct WorkspaceSetupRunResult {
        let exitCode: Int
        let logPath: String
    }

    struct BuiltInTerminalSessionOwnership {
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
        let windowRecordInsertedBeforeLaunch: Bool
        let appName: String
        let title: String
        let launchConfiguration: TerminalSessionLaunchConfiguration
        let createdAt: String
        let orderIndex: Int
    }

    enum ManagedTerminalFocusResult {
        case existingWindow
        case trackedTerminal
        case sessionRequest
        case reboundSession(windowID: Int?)
        case reopenedSession(windowID: Int?)
        case unavailable
    }

    struct WorkspaceProcessFocusOutcome {
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

    enum WorkspaceNavigationTarget {
        case agent(AgentWindowRecord)
        case browser(WindowRecord)
        case process(RunningProcessRecord)
        case window(WindowRecord)
    }

    enum FocusableWorkspaceTarget {
        case agent(AgentWindowRecord)
        case browserSession(targetURL: String)
        case configuredProcess(name: String)
        case process(RunningProcessRecord)
        case window(WindowRecord)
    }

    public let store: SQLiteStore
    let git: GitClient
    let yabai: YabaiAdapter
    let chrome: ChromeAdapter
    let browserWindowScanDebounceInterval: TimeInterval
    let currentDate: () -> Date
    let notificationDeliverer: (String, String, String?) -> Void
    let builtInTerminalWindowOpener: BuiltInTerminalWindowOpener
    let builtInTerminalWindowFocuser: BuiltInTerminalWindowFocuser
    let builtInTerminalWindowCloser: BuiltInTerminalWindowCloser
    let builtInTerminalSessionTerminator: BuiltInTerminalSessionTerminator
    let builtInTerminalSessionLauncher: BuiltInTerminalSessionLauncher
    let windowFocusPulseEnabledProvider: () throws -> Bool
    let windowFocusPulseColorProvider: () throws -> (r: Int, g: Int, b: Int)
    private let projectsRootDirectoryURL: URL?
    private let workspacesRootDirectoryURL: URL?
    private let workspaceLifecycleLock = NSLock()
    private var workspaceLifecycleInFlight: Set<String> = []
    let workspaceSetupLock = NSLock()
    var workspaceSetupInFlight: Set<String> = []
    private let windowNavigationLock = NSLock()
    private var windowNavigationCursorByWorkspace: [String: WorkspaceNavigationCursor] = [:]
    private var windowNavigationHistoryByWorkspace: [String: [WorkspaceNavigationCursor]] = [:]
    private var windowNavigationCycleSessionByWorkspace: [String: WorkspaceNavigationCycleSession] = [:]
    let browserScanCacheLock = NSLock()
    var browserWindowScanCacheByWorkspace: [String: BrowserWindowScanCacheEntry] = [:]
    let terminalFocusPulseController: TerminalFocusPulseControlling
    private let windowNavigationCycleSessionTimeout: TimeInterval = 2
    private let windowNavigationHistoryLimit = 64

    public init(
        store: SQLiteStore, projectsRootDirectory: URL? = nil, workspacesRootDirectory: URL? = nil, git: GitClient = .init(),
        yabai: YabaiAdapter = .init(), chrome: ChromeAdapter = .init(),
        browserWindowScanDebounceInterval: TimeInterval = PollingConstants.browserWindowScanDebounceInterval,
        terminalFocusPulseController: TerminalFocusPulseControlling = TerminalFocusPulseController(),
        notificationDeliverer: ((String, String, String?) -> Void)? = nil, builtInTerminalWindowOpener: BuiltInTerminalWindowOpener? = nil,
        builtInTerminalWindowFocuser: BuiltInTerminalWindowFocuser? = nil, builtInTerminalWindowCloser: BuiltInTerminalWindowCloser? = nil,
        builtInTerminalSessionTerminator: BuiltInTerminalSessionTerminator? = nil,
        builtInTerminalSessionLauncher: BuiltInTerminalSessionLauncher? = nil,
        windowFocusPulseEnabledProvider: (() throws -> Bool)? = nil, windowFocusPulseColorProvider: (() throws -> (r: Int, g: Int, b: Int))? = nil,
        currentDate: @escaping () -> Date = Date.init
    ) {
        self.store = store
        projectsRootDirectoryURL = projectsRootDirectory
        self.git = git
        self.yabai = yabai
        self.chrome = chrome
        self.workspacesRootDirectoryURL = workspacesRootDirectory
        self.browserWindowScanDebounceInterval = browserWindowScanDebounceInterval
        self.terminalFocusPulseController = terminalFocusPulseController
        self.notificationDeliverer = notificationDeliverer ?? Self.deliverUserNotification
        self.windowFocusPulseEnabledProvider = windowFocusPulseEnabledProvider ?? { SettingsKey.defaultWindowFocusPulseEnabled }
        self.windowFocusPulseColorProvider = windowFocusPulseColorProvider ?? { SettingsKey.windowFocusPulseColor(from: nil) }
        #if canImport(Darwin)
            self.builtInTerminalWindowOpener =
                builtInTerminalWindowOpener ?? { sessionID, mode in
                    try? IPCNotification.post(
                        IPCNotification.openTerminalSessionWindow,
                        userInfo: [
                            IPCNotification.terminalSessionIDUserInfoKey: sessionID, IPCNotification.terminalAttachmentModeUserInfoKey: mode.rawValue,
                        ])
                }
            self.builtInTerminalWindowFocuser =
                builtInTerminalWindowFocuser ?? { sessionID, requestID in
                    var userInfo: [String: String] = [
                        IPCNotification.terminalSessionIDUserInfoKey: sessionID,
                        IPCNotification.terminalAttachmentModeUserInfoKey: TerminalAttachmentMode.owner.rawValue,
                    ]
                    if let requestID, !requestID.isEmpty { userInfo[IPCNotification.focusRequestIDUserInfoKey] = requestID }
                    try? IPCNotification.post(IPCNotification.openTerminalSessionWindow, userInfo: userInfo)
                }
            self.builtInTerminalWindowCloser =
                builtInTerminalWindowCloser ?? { sessionID in
                    try? IPCNotification.post(
                        IPCNotification.closeTerminalSessionWindow,
                        userInfo: [
                            IPCNotification.terminalSessionIDUserInfoKey: sessionID, IPCNotification.terminalSessionIsTerminatingUserInfoKey: "true",
                        ])
                }
            self.builtInTerminalSessionTerminator =
                builtInTerminalSessionTerminator ?? Self.builtInTerminalSessionTerminatorOverrideStore.get() ?? { sessionID in
                    try? TerminalService.terminateSession(id: sessionID)
                }
            self.builtInTerminalSessionLauncher =
                builtInTerminalSessionLauncher ?? Self.builtInTerminalSessionLauncherOverrideStore.get() ?? { launchConfiguration in
                    try TerminalService.createSession(launchConfiguration)
                }
        #else
            self.builtInTerminalWindowOpener = builtInTerminalWindowOpener ?? { _, _ in }
            self.builtInTerminalWindowFocuser = builtInTerminalWindowFocuser ?? { _, _ in }
            self.builtInTerminalWindowCloser = builtInTerminalWindowCloser ?? { _ in }
            self.builtInTerminalSessionTerminator =
                builtInTerminalSessionTerminator ?? Self.builtInTerminalSessionTerminatorOverrideStore.get() ?? { _ in }
            self.builtInTerminalSessionLauncher =
                builtInTerminalSessionLauncher ?? Self.builtInTerminalSessionLauncherOverrideStore.get() ?? { _ in
                    throw WorkspaceError.invalidArgument(message: "Local TerminalService launch is unavailable in this spacesd build.")
                }
        #endif
        self.currentDate = currentDate
        if ProcessInfo.processInfo.environment["DEBUG"] == "1" {
            Self.writeStandardError("spaces: DEBUG=1 enabled (browser/cycle profiling active)\n")
        }
    }

    @discardableResult public func syncConfig() throws -> AppConfig { try store.appConfig() }

    public func appConfig() throws -> AppConfig { try store.appConfig() }

    public func effectiveSpacesDevice(workspaceID: String) throws -> SpacesDeviceSelection {
        guard let workspace = try store.workspace(id: workspaceID) else { throw WorkspaceError.invalidArgument(message: "Workspace not found.") }
        guard try store.project(id: workspace.projectID) != nil else { throw WorkspaceError.missingProject(dir: workspace.projectID) }
        return .local(SpacesDeviceRecord.local())
    }

    public func workspaceRuntimePlan(workspaceID: String) throws -> WorkspaceRuntimePlan {
        guard let workspace = try store.workspace(id: workspaceID) else { throw WorkspaceError.invalidArgument(message: "Workspace not found.") }
        guard let project = try store.project(id: workspace.projectID) else { throw WorkspaceError.missingProject(dir: workspace.projectID) }
        return try workspaceRuntimePlan(
            project: project, workspace: workspace, assignedPorts: try store.workspacePortsAssigned(workspaceID: workspace.id))
    }

    public func project(id: String) throws -> ProjectRecord? { try store.project(id: id) }

    public func project(dir: String) throws -> ProjectRecord? { try store.project(dir: dir) }

    public func listWorkspaces(projectID: String, includeArchived: Bool = false) throws -> [WorkspaceSummary] {
        let records = try store.workspaces(projectID: projectID, includeArchived: includeArchived)
        return records.map {
            WorkspaceSummary(
                id: $0.id, title: $0.title, branch: $0.branch, baseBranch: $0.baseBranch, dir: $0.dir, isRunning: $0.isRunning,
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
        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) },
            runtimeManifest: try workspaceRuntimePlan(project: project, workspace: workspace, assignedPorts: assignedPorts).manifest)
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
                if let existing = try workspaceForBranch(projectID: workspace.projectID, branch: trimmedBranch, deviceID: workspace.deviceID),
                    existing.id != workspace.id
                {
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
            baseBranch: workspace.baseBranch, isDefault: workspace.isDefault, isArchived: workspace.isArchived, isHidden: workspace.isHidden,
            isRunning: workspace.isRunning, lastLaunchedAt: workspace.lastLaunchedAt, notes: updatedNotes)
        try store.upsert(workspace: updatedWorkspace)
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

    public func createWorkspace(
        projectID: String, name: String, branch: String? = nil, baseBranch: String? = nil, directoryName: String? = nil, runSetupScript: Bool = true,
        allowRemoteBranchLookup: Bool = true, allowExistingBranchReuse: Bool = false, replaceExistingManagedDirectory: Bool = false
    ) throws -> WorkspaceRecord {
        guard let project = try store.project(id: projectID) else { throw WorkspaceError.missingProject(dir: projectID) }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw WorkspaceError.invalidArgument(message: "Workspace name is required.") }
        let trimmedDirectoryName = directoryName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacesExplicitManagedDirectory = replaceExistingManagedDirectory && trimmedDirectoryName?.isEmpty == false
        let trimmedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBranch: String?
        let resolvedBaseBranch: String?
        if project.isGitRepo {
            guard let trimmedBranch, !trimmedBranch.isEmpty else {
                throw WorkspaceError.invalidArgument(message: "Branch name is required for git projects.")
            }
            resolvedBranch = trimmedBranch
            resolvedBaseBranch = try resolveWorkspaceBaseBranch(project: project, baseBranch: baseBranch)
        } else {
            if let trimmedDirectoryName, !trimmedDirectoryName.isEmpty {
                throw WorkspaceError.invalidArgument(message: "Directory name override is only supported for git projects.")
            }
            resolvedBranch = nil
            resolvedBaseBranch = nil
        }
        if project.isGitRepo, let branchName = resolvedBranch {
            if let existing = try workspaceForBranch(projectID: projectID, branch: branchName, deviceID: SpacesDeviceRecord.localDeviceID) {
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
        if project.isGitRepo, let branchName = resolvedBranch,
            let existing = try archivedWorkspace(projectID: projectID, branch: branchName, deviceID: SpacesDeviceRecord.localDeviceID)
        {
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
                    path: project.dir, worktreePath: revivedDir, branch: branchName, baseBranch: resolvedBaseBranch,
                    allowRemoteBranchLookup: allowRemoteBranchLookup)
            }
            revivedBranch = branchName
            let revived = WorkspaceRecord(
                id: existing.id, projectID: project.id, title: trimmedName, dir: revivedDir, dirname: revivedDirname, branch: revivedBranch,
                baseBranch: existing.baseBranch ?? resolvedBaseBranch, isDefault: false, isArchived: false, isHidden: existing.isHidden,
                isRunning: false, lastLaunchedAt: nil)
            try store.upsert(workspace: revived)
            try seedWorkspaceSettings(project: project, workspace: revived)
            try initializeWorkspaceRuntime(project: project, workspace: revived, runSetupScript: runSetupScript)
            return revived
        }
        if !project.isGitRepo, let existing = try archivedWorkspace(projectID: projectID, dir: project.dir) {
            let revived = WorkspaceRecord(
                id: existing.id, projectID: project.id, title: trimmedName, dir: project.dir, dirname: existing.dirname, branch: nil, baseBranch: nil,
                isDefault: false, isArchived: false, isHidden: existing.isHidden, isRunning: false, lastLaunchedAt: nil)
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
                path: project.dir, worktreePath: workspaceDir, branch: branchName, baseBranch: resolvedBaseBranch,
                allowRemoteBranchLookup: allowRemoteBranchLookup)
            workspaceBranch = branchName
        } else {
            workspaceDir = project.dir
            workspaceDirname = nil
            workspaceBranch = nil
        }
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, title: trimmedName, dir: workspaceDir, dirname: workspaceDirname, branch: workspaceBranch,
            baseBranch: resolvedBaseBranch, isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        try seedWorkspaceSettings(project: project, workspace: workspace)
        try initializeWorkspaceRuntime(project: project, workspace: workspace, runSetupScript: runSetupScript)

        return workspace
    }

    public func createWorkspaceOnDevice(
        projectID: String, name: String, branch: String, baseBranch: String? = nil, directoryName: String? = nil,
        notes: String? = nil, runSetupScript: Bool = true, allowRemoteBranchLookup: Bool = true, allowExistingBranchReuse: Bool = false
    ) throws -> WorkspaceRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw WorkspaceError.invalidArgument(message: "Workspace name is required.") }
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { throw WorkspaceError.invalidArgument(message: "Branch name is required for git projects.") }
        var workspace = try createWorkspace(
            projectID: projectID, name: trimmedName, branch: trimmedBranch, baseBranch: baseBranch, directoryName: directoryName,
            runSetupScript: runSetupScript, allowRemoteBranchLookup: allowRemoteBranchLookup, allowExistingBranchReuse: allowExistingBranchReuse)
        if let notes {
            try updateWorkspaceNotes(workspaceID: workspace.id, notes: notes)
            workspace = try store.workspace(id: workspace.id) ?? workspace
        }
        return workspace
    }

    private func resolveWorkspaceBaseBranch(project: ProjectRecord, baseBranch: String?) throws -> String {
        if let baseBranch = baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines), !baseBranch.isEmpty { return baseBranch }
        if let configured = project.defaultBranch, !configured.isEmpty { return configured }
        if git.branchExists(path: project.dir, branch: "main") || git.remoteBranchExists(path: project.dir, branch: "main") { return "main" }
        if git.branchExists(path: project.dir, branch: "master") || git.remoteBranchExists(path: project.dir, branch: "master") { return "master" }
        throw WorkspaceError.invalidArgument(message: "Base branch is required for git projects.")
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
        if let existing = try workspaceForBranch(projectID: project.id, branch: branch, deviceID: SpacesDeviceRecord.localDeviceID) {
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
                        branch: worktree.branchName, baseBranch: workspace.baseBranch, isDefault: workspace.isDefault,
                        isArchived: workspace.isArchived, isHidden: workspace.isHidden, isRunning: workspace.isRunning,
                        lastLaunchedAt: workspace.lastLaunchedAt, notes: workspace.notes)
                    try store.upsert(workspace: updatedWorkspace)
                }

                guard workspace.deviceID == SpacesDeviceRecord.localDeviceID else { continue }
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

    private func workspaceForBranch(projectID: String, branch: String, deviceID: String) throws -> WorkspaceRecord? {
        try store.workspaces(projectID: projectID, includeArchived: true).first { $0.branch == branch && $0.deviceID == deviceID }
    }

    private func archivedWorkspace(projectID: String, branch: String, deviceID: String) throws -> WorkspaceRecord? {
        try store.workspaces(projectID: projectID, includeArchived: true).first { $0.branch == branch && $0.deviceID == deviceID && $0.isArchived }
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

        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let runtimePlan = try workspaceRuntimePlan(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) },
            runtimeManifest: runtimePlan.manifest)
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
            newWindows.append(
                contentsOf: try launchProcesses(
                    workspace: workspace, templates: config.processes, env: env, background: background))
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
                terminalNativeID: window.terminalNativeID, role: window.role, orderIndex: index, lastSeenAt: window.lastSeenAt)
            index += 1
            try store.upsert(window: stored)
        }

        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: nowISO8601())
        shouldRestoreReservedPorts = false
    }

    @discardableResult public func stopWorkspace(workspaceID: String) throws -> WorkspaceStopOutcome {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) { try stopWorkspaceUnlocked(workspaceID: workspaceID) }
    }

    private func stopWorkspaceUnlocked(workspaceID: String, waitForTerminalExit: Bool = true) throws -> WorkspaceStopOutcome {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let windows = try indexedWorkspaceWindows(workspaceID: workspace.id)
        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let runtimePlan = try workspaceRuntimePlan(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) },
            runtimeManifest: runtimePlan.manifest)
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
        if waitForTerminalExit { waitForBuiltInTerminalSessionsToExit(closedBuiltInTerminalSessionIDs) }
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
        _ = try stopWorkspaceUnlocked(workspaceID: workspaceID, waitForTerminalExit: false)
        try store.deleteAgentWindows(workspaceID: workspaceID)
        if project.isGitRepo, workspace.deviceID == SpacesDeviceRecord.localDeviceID {
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

    private func missingRuntimeRecordCount(expectedKeys: [String], actualKeys: [String]) -> Int {
        var actualCounts: [String: Int] = [:]
        for key in actualKeys { actualCounts[key, default: 0] += 1 }

        var missingCount = 0
        for key in expectedKeys {
            if let currentCount = actualCounts[key], currentCount > 0 { actualCounts[key] = currentCount - 1 } else { missingCount += 1 }
        }
        return missingCount
    }

    func withWorkspaceLifecycleLock<T>(workspaceID: String, operation: () throws -> T) throws -> T {
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


    #if canImport(UserNotifications)
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
    #else
        private static func deliverUserNotification(title _: String, body _: String, subtitle _: String? = nil) {}

        public static func prepareUserNotificationAuthorization() {}
    #endif

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
                terminalNativeID: window.terminalNativeID, role: window.role, orderIndex: window.orderIndex, lastSeenAt: window.lastSeenAt)
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

    @discardableResult public func openWorkspaceTerminal(workspaceID: String) throws -> String {
        let reservation = try reserveWorkspaceTerminalLaunch(workspaceID: workspaceID)
        try finishReservedWorkspaceTerminalLaunch(reservation)
        return reservation.sessionID
    }

    @discardableResult public func createWorkspaceTerminalSession(workspaceID: String, title: String?, command: String?) throws
        -> TerminalServiceSessionSummary
    {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isArchived else { throw WorkspaceError.invalidArgument(message: "Workspace is archived.") }
        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspaceID)
        let sessionID = UUID().uuidString
        let runtimePlan = try workspaceRuntimePlan(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = terminalLaunchEnvironment(
            base: buildWorkspaceEnv(
                project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) },
                runtimeManifest: runtimePlan.manifest
            ).merging([Self.terminalTrackingIDEnvVar: sessionID]) { _, new in new }, includeInheritedPath: false, includeProfileEnvironment: true
        )
        let shellPath = terminalShellPathOverride() ?? "/bin/zsh"
        let rawCommand: String
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawCommand = command
        } else {
            rawCommand = interactiveShellCommand(cwd: workspace.dir)
        }
        let launchCommand = commandPrefixedWithShellEnvironment(rawCommand, env: env)
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: title ?? "shell", workingDirectory: workspace.dir,
            shell: shellPath, command: launchCommand, createdAt: nowISO8601(), workspaceID: workspace.id, kind: .shell)

        let session = try builtInTerminalSessionLauncher(launchConfiguration)
        if !workspace.isRunning {
            let launchedAt = workspace.lastLaunchedAt ?? nowISO8601()
            try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: launchedAt)
        }
        return session
    }

    public func reserveWorkspaceTerminalLaunch(workspaceID: String) throws -> WorkspaceTerminalLaunchReservation {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isArchived else { throw WorkspaceError.invalidArgument(message: "Workspace is archived.") }
        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspaceID)
        let sessionID = UUID().uuidString
        let runtimePlan = try workspaceRuntimePlan(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = terminalLaunchEnvironment(
            base: buildWorkspaceEnv(
                project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) },
                runtimeManifest: runtimePlan.manifest
            ).merging([Self.terminalTrackingIDEnvVar: sessionID]) { _, new in new }, includeInheritedPath: false, includeProfileEnvironment: true
        )
        let generatedTitle = try generatedAdHocTerminalWindowName(workspaceID: workspace.id)
        let workingDirectory = workspace.dir
        let shellPath = terminalShellPathOverride() ?? "/bin/zsh"
        let shellCommand = interactiveShellCommand(cwd: workspace.dir)
        let command = commandPrefixedWithShellEnvironment(shellCommand, env: env)
        let createdAt = nowISO8601()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: generatedTitle, workingDirectory: workingDirectory,
            shell: shellPath, command: command, createdAt: createdAt, workspaceID: workspace.id, kind: .shell)
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: sessionID, backend: launchConfiguration.backend, servicePID: ProcessInfo.processInfo.processIdentifier, childPID: nil,
                state: .starting, updatedAt: createdAt, title: generatedTitle, workingDirectory: workingDirectory), paths: paths)
        _ = FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
        _ = FileManager.default.createFile(atPath: paths.serviceLogPath, contents: nil)
        let existing = try store.windows(workspaceID: workspace.id)
        let nextOrder = Self.nextWindowOrderIndex(existing: existing, role: "terminal", orderOffset: 200)
        let windowRecordID = UUID().uuidString
        let appName = TerminalHost.spaces.appName
        try store.upsert(
            window: WindowRecord(
                id: windowRecordID, workspaceID: workspace.id, app: appName, name: generatedTitle, detail: nil, targetURL: nil, windowID: nil,
                terminalTrackingID: sessionID, terminalNativeID: sessionID, role: "terminal", orderIndex: nextOrder, lastSeenAt: nowISO8601()))
        if !workspace.isRunning {
            let launchedAt = workspace.lastLaunchedAt ?? nowISO8601()
            try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: launchedAt)
        }
        return WorkspaceTerminalLaunchReservation(
            sessionID: sessionID, workspaceID: workspace.id, windowRecordID: windowRecordID, windowRecordInsertedBeforeLaunch: true, appName: appName,
            title: generatedTitle, launchConfiguration: launchConfiguration, createdAt: createdAt, orderIndex: nextOrder)
    }

    @discardableResult public func finishReservedWorkspaceTerminalLaunch(_ reservation: WorkspaceTerminalLaunchReservation) throws -> String {
        do {
            if reservation.windowRecordInsertedBeforeLaunch {
                guard try reservedWorkspaceTerminalWindowExists(reservation) else {
                    markReservedWorkspaceTerminalLaunchFailed(reservation)
                    return reservation.sessionID
                }
            }
            let session = try launchSpacesTerminalSession(
                title: reservation.launchConfiguration.title, workingDirectory: reservation.launchConfiguration.workingDirectory,
                command: reservation.launchConfiguration.command, showMode: .owner, backend: reservation.launchConfiguration.backend,
                readinessPolicy: .stableChildPID, sessionID: reservation.sessionID,
                lifetimePolicy: reservation.launchConfiguration.lifetimePolicy, workspaceID: reservation.launchConfiguration.workspaceID,
                kind: reservation.launchConfiguration.kind)
            if reservation.windowRecordInsertedBeforeLaunch {
                guard try reservedWorkspaceTerminalWindowExists(reservation) else {
                    builtInTerminalSessionTerminator(reservation.sessionID)
                    return session.sessionID
                }
            }
            let existingWindow = try store.windows(workspaceID: reservation.workspaceID).first { $0.id == reservation.windowRecordID }
            try store.upsert(
                window: WindowRecord(
                    id: reservation.windowRecordID, workspaceID: reservation.workspaceID, app: reservation.appName, name: reservation.title,
                    detail: nil, targetURL: nil, windowID: session.windowID ?? existingWindow?.windowID, terminalTrackingID: session.sessionID,
                    terminalNativeID: session.sessionID, role: "terminal", orderIndex: reservation.orderIndex, lastSeenAt: nowISO8601()))
            try markWorkspaceRunningIfNeeded(workspaceID: reservation.workspaceID, launchedAtFallback: reservation.createdAt)
            return session.sessionID
        } catch {
            markReservedWorkspaceTerminalLaunchFailed(reservation)
            builtInTerminalWindowCloser(reservation.sessionID)
            throw error
        }
    }

    public func cancelReservedWorkspaceTerminalLaunch(_ reservation: WorkspaceTerminalLaunchReservation) {
        markReservedWorkspaceTerminalLaunchFailed(reservation)
    }

    private func markReservedWorkspaceTerminalLaunchFailed(_ reservation: WorkspaceTerminalLaunchReservation) {
        let now = nowISO8601()
        if let paths = try? TerminalSessionPaths.forSession(id: reservation.sessionID) {
            let previousRuntimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
            let failedState = TerminalSessionRuntimeState(
                sessionID: reservation.sessionID, backend: previousRuntimeState?.backend ?? reservation.launchConfiguration.backend,
                servicePID: previousRuntimeState?.servicePID ?? ProcessInfo.processInfo.processIdentifier, childPID: previousRuntimeState?.childPID,
                state: .failed, updatedAt: now, exitedAt: now, title: previousRuntimeState?.title ?? reservation.launchConfiguration.title,
                workingDirectory: previousRuntimeState?.workingDirectory ?? reservation.launchConfiguration.workingDirectory,
                columns: previousRuntimeState?.columns, rows: previousRuntimeState?.rows, foregroundPID: previousRuntimeState?.foregroundPID,
                foregroundExecutablePath: previousRuntimeState?.foregroundExecutablePath,
                foregroundExecutableName: previousRuntimeState?.foregroundExecutableName, foregroundArgv: previousRuntimeState?.foregroundArgv,
                foregroundDetectedAgentKind: previousRuntimeState?.foregroundDetectedAgentKind,
                foregroundDisplayLabel: previousRuntimeState?.foregroundDisplayLabel,
                foregroundDisplayCommand: previousRuntimeState?.foregroundDisplayCommand)
            try? TerminalSessionPersistence.writeRuntimeState(failedState, paths: paths)
            try? TerminalSessionPersistence.detachActiveClients(paths: paths, detachedAt: now)
            try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
            try? FileManager.default.removeItem(atPath: paths.subscriptionSocketPath)
        }
        try? store.deleteWindow(id: reservation.windowRecordID)
        try? clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: reservation.workspaceID)
    }

    private func markWorkspaceRunningIfNeeded(workspaceID: String, launchedAtFallback: String) throws {
        guard let workspace = try store.workspace(id: workspaceID), !workspace.isRunning else { return }
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: workspace.lastLaunchedAt ?? launchedAtFallback)
    }

    private func reservedWorkspaceTerminalWindowExists(_ reservation: WorkspaceTerminalLaunchReservation) throws -> Bool {
        try store.windows(workspaceID: reservation.workspaceID).contains { $0.id == reservation.windowRecordID }
    }

    public func focusWorkspace(workspaceID: String) throws {
        let windows = try indexedWorkspaceWindows(workspaceID: workspaceID)
        for window in windows {
            let ok = focusTrackedWindow(window, workspaceID: workspaceID, requestID: nil)
            if ok {
                rememberNavigationTarget(navigationTarget(for: window), workspaceID: workspaceID)
                break
            }
        }
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
        if ok { rememberNavigationTarget(navigationTarget(for: windows[targetIndex]), workspaceID: workspaceID) }
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
        logPerfMetric(
            "browser_focus", workspaceID: workspaceID, target: targetURL, detail: "recovered=1", elapsedMS: elapsedMS(since: focusStartedAt),
            success: true)
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

    func focusableWorkspaceTargets(workspaceID: String) throws -> [(name: String, target: FocusableWorkspaceTarget)] {
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

    func rememberNavigationTarget(_ target: WorkspaceNavigationTarget, workspaceID: String, asCycleNavigation: Bool = false) {
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

    func sanitizedFocusName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func normalizedFocusName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    func requiredConfiguredFocusName(_ name: String?, kind: String) throws -> String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let sanitized = sanitizedFocusName(trimmedName), !sanitized.isEmpty else {
            throw WorkspaceError.invalidArgument(message: "\(kind) name is required.")
        }
        return sanitized
    }

    func validateUniqueConfiguredFocusNames(processes: [ProcessTemplate], browserSessions: [BrowserSession], agentLaunchers: [AgentLauncher])
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

    func validateWorkspaceFocusNames(
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

    func focusTrackedWindow(_ window: WindowRecord, workspaceID: String, requestID: String?, sourceBuiltInTerminalSessionID: String? = nil)
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
                let scannedFocus = (try? focusScannedBrowserTab(workspaceID: workspaceID, targetURL: targetURL)) ?? false
                logBrowserFocus(
                    "workspace=\(workspaceID) path=chrome_scanned_tab_from_built_in window=\(windowID) success=\(scannedFocus ? "1" : "0") elapsed_ms=\(elapsedMS(since: chromeFocusByWindowStartedAt)) request_id=\(requestID)"
                )
                if scannedFocus {
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

    func commandPrefixedWithShellEnvironment(_ command: String, env: [String: String]) -> String {
        guard !env.isEmpty else { return command }
        let exports = env.sorted(by: { $0.key < $1.key }).map { "export \($0.key)=\(shellQuoted($0.value))" }.joined(separator: "; ")
        return "\(exports); \(command)"
    }

    enum BuiltInTerminalReadinessPolicy: String {
        case sessionReady = "session_ready"
        case stableChildPID = "stable_child_pid"
    }

    func shellQuoted(_ token: String) -> String {
        guard !token.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/:")
        if token.unicodeScalars.allSatisfy({ safe.contains($0) }) { return token }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func commandWithPrelude(_ command: String, prelude: String?) -> String {
        guard let prelude = prelude?.trimmingCharacters(in: .whitespacesAndNewlines), !prelude.isEmpty else { return command }
        return "\(prelude); \(command)"
    }

    private func indexedWorkspaceWindows(workspaceID: String) throws -> [WindowRecord] {
        try store.windows(workspaceID: workspaceID).sorted { $0.orderIndex < $1.orderIndex }
    }

    func elapsedMS(since startedAt: Date) -> Int { Int(currentDate().timeIntervalSince(startedAt) * 1000) }

    private func logCycleProfile(_ message: String) {
        guard debugLoggingEnabled() else { return }
        Self.writeStandardError("spaces: cycle \(message)\n")
    }

    func logPerfMetric(_ metric: String, workspaceID: String, target: String, detail: String = "", elapsedMS: Int, success: Bool) {
        // Manual real-system E2E parses these `spaces: perf metric=...` lines for
        // focus/cycle timing summaries. Treat the prefix and key/value shape as a
        // compatibility surface for the shell harness when changing debug logs.
        TerminalPerformance.logWorkspaceMetric(
            metric, workspaceID: workspaceID, target: target, elapsedMS: elapsedMS, success: success, detail: detail)
    }

    func debugLoggingEnabled() -> Bool { ProcessInfo.processInfo.environment["DEBUG"] == "1" }

    static func writeStandardError(_ message: String) { FileHandle.standardError.write(Data(message.utf8)) }

    private func navigationTargetDebugName(_ target: WorkspaceNavigationTarget) -> String {
        switch target {
        case .agent(let record): return "agent:\(record.label ?? record.provider.rawValue)"
        case .browser(let window): return "browser:\(window.targetURL ?? window.name ?? "")"
        case .process(let process): return "process:\(process.templateName)"
        case .window(let window): return "\(window.role):\(window.name ?? window.app)"
        }
    }

    public func listSpaceOptions() throws -> [SpaceOption] {
        let spaces = try yabai.listSpaces()
        return spaces.map { SpaceOption(displayIndex: $0.display, spaceIndex: $0.index) }.sorted { lhs, rhs in
            if lhs.displayIndex == rhs.displayIndex { return lhs.spaceIndex < rhs.spaceIndex }
            return lhs.displayIndex < rhs.displayIndex
        }
    }

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

    func normalizeDir(id: String, _ dir: String) throws -> ProjectRecord {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceError.invalidArgument(message: "Project directory not found: \(dir)")
        }
        let isGit = git.isRepo(path: dir)
        let branch = isGit ? git.defaultBranch(path: dir) : nil
        let name = URL(fileURLWithPath: dir).lastPathComponent
        return ProjectRecord(id: id, name: name, dir: dir, isGitRepo: isGit, defaultBranch: branch)
    }

    func ensureDefaultWorkspace(for project: ProjectRecord) throws {
        if let existing = try defaultWorkspace(projectID: project.id) {
            if existing.isArchived {
                let revived = WorkspaceRecord(
                    id: existing.id, projectID: project.id, title: existing.title, dir: existing.dir, dirname: existing.dirname,
                    branch: existing.branch, baseBranch: existing.baseBranch, isDefault: true, isArchived: false, isHidden: existing.isHidden,
                    isRunning: existing.isRunning, lastLaunchedAt: existing.lastLaunchedAt)
                try store.upsert(workspace: revived)
            }
            return
        }
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, title: "default", dir: project.dir, dirname: nil, branch: project.defaultBranch,
            baseBranch: project.defaultBranch, isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        try seedWorkspaceSettings(project: project, workspace: workspace)
        let appConfig = try store.appConfig()
        let portDefinitions = try store.workspacePortDefinitions(workspaceID: workspace.id)
        _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, definitions: portDefinitions, range: appConfig.portRange)
    }

    func resolveWorkspace(id: String) throws -> (ProjectRecord, WorkspaceRecord) {
        guard let workspace = try store.workspace(id: id) else { throw WorkspaceError.invalidArgument(message: "Workspace not found.") }
        guard let project = try store.project(id: workspace.projectID) else { throw WorkspaceError.missingProject(dir: workspace.projectID) }
        return (project, workspace)
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

    func spacesYAMLDocumentIfPresent(in directory: URL) throws -> SpacesYAMLDocument? {
        let url = directory.appendingPathComponent(SpacesYAMLService.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try SpacesYAMLService.load(from: url)
    }

    func workspaceConfigurationSnapshots(projectID: String) throws -> [WorkspaceConfigurationSnapshot] {
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

    func restoreSpacesYAMLImportSnapshot(project: ProjectRecord, workspaces: [WorkspaceConfigurationSnapshot]) throws {
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

    func seedWorkspaceSettings(project: ProjectRecord, workspace: WorkspaceRecord) throws {
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

    func loadWorkspaceSettings(project: ProjectRecord, workspace: WorkspaceRecord) throws -> WorkspaceSettings? {
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


    func buildWorkspaceEnv(
        project: ProjectRecord, workspace: WorkspaceRecord, namedPorts: [(port: Int, name: String)], runtimeManifest: WorkspaceRuntimeManifest? = nil
    ) -> [String: String] {
        var env: [String: String] = [:]
        for namedPort in namedPorts {
            let key = namedPort.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            env[key] = String(namedPort.port)
        }
        let manifest =
            runtimeManifest
            ?? SpacesDevicePlanner.runtimeManifest(
                project: project, workspace: workspace, selection: .local(SpacesDeviceRecord.local()),
                namedPorts: namedPorts.map { WorkspaceRuntimePortMapping(id: $0.name, name: $0.name, port: $0.port) })
        env.merge(manifest.processEnvironment) { _, new in new }
        let runtimeWorkspacePath =
            manifest.location == .remote ? manifest.remotePath?.trimmingCharacters(in: .whitespacesAndNewlines) : workspace.runtimePath
        let workspacePath = runtimeWorkspacePath.flatMap { $0.isEmpty ? nil : $0 } ?? workspace.runtimePath
        env["SPACES_WORKSPACE_DIR"] = workspacePath
        env["SPACES_PROJECT_DIR"] = manifest.location == .remote ? workspacePath : project.dir
        return env
    }

    func workspaceRuntimePlan(
        project: ProjectRecord, workspace: WorkspaceRecord, assignedPorts: [(definitionID: String, port: Int, name: String)]
    ) throws -> WorkspaceRuntimePlan {
        let selection = try effectiveSpacesDevice(workspaceID: workspace.id)
        let namedPorts = assignedPorts.map {
            WorkspaceRuntimePortMapping(id: $0.definitionID.isEmpty ? $0.name : $0.definitionID, name: $0.name, port: $0.port)
        }
        let manifest = SpacesDevicePlanner.runtimeManifest(
            project: project, workspace: workspace, selection: selection, namedPorts: namedPorts)
        let daemonTarget = SpacesDevicePlanner.daemonTarget(selection: selection, localSocketPath: try TerminalServicePaths.socketPath())
        return WorkspaceRuntimePlan(
            project: project, workspace: workspace, selection: selection, manifest: manifest, daemonTarget: daemonTarget, remoteSSHURI: nil)
    }

    struct RunningWorkspaceProcessEdit {
        let previous: ProcessTemplate
        let updated: ProcessTemplate
        let previousKey: String
        let updatedKey: String

        var commandChanged: Bool { previous.command != updated.command }
        var keyChanged: Bool { previousKey != updatedKey }
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

    private func windowTrackingKey(_ window: WindowRecord) -> String {
        let idPart = window.windowID.map(String.init) ?? "none"
        if window.role == "browser" { return "browser:\(idPart):\(window.targetURL ?? "")" }
        if window.role == "terminal", window.windowID == nil {
            let app = window.app.lowercased()
            if let terminalNativeID = window.terminalNativeID, !terminalNativeID.isEmpty { return "terminal:\(app):native:\(terminalNativeID)" }
            if let terminalTrackingID = window.terminalTrackingID, !terminalTrackingID.isEmpty {
                return "terminal:\(app):tracking:\(terminalTrackingID)"
            }
        }
        return "\(window.role):\(idPart)"
    }

    static func nextWindowOrderIndex(existing: [WindowRecord], role: String, orderOffset: Int) -> Int {
        let maxIndex = existing.filter { $0.role == role }.map(\.orderIndex).max() ?? (orderOffset - 1)
        return max(maxIndex + 1, orderOffset)
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

    func bestEffortYabaiWindowSnapshot() -> [YabaiWindow] { (try? yabai.listWindows()) ?? [] }

    func bestEffortCaptureNewAppWindowID(snapshot: [YabaiWindow], appName: String) -> Int? {
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

    func runtimeDirectory() throws -> String { try SpacesProfile.current().runtimeDirectory }

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

    func resolvedRuntimePID(for process: RunningProcessRecord) -> Int? {
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

    private func runtimePID(fromFile path: String) -> Int? {
        guard let contents = try? String(contentsOfFile: path) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int(trimmed), pid > 0 else { return nil }
        return pid
    }

    func nowISO8601() -> String { ISO8601DateFormatter().string(from: Date()) }

    func normalizePath(_ path: String) -> String {
        let expanded = expandTilde(path)
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func standardizePathPreservingSymlinks(_ path: String) -> String {
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

    func worktreeRoot(project: ProjectRecord) throws -> URL {
        let projectDirname: String
        if isManagedRepositoryDirectory(path: normalizePath(project.dir)) {
            // Managed git clones live at repos/<leaf>; mirror that leaf under the
            // workspaces root so the worktree root stays deterministic from the
            // import URL (enabling orphaned-folder detection on re-import) even
            // though the project id is an opaque unique identifier.
            projectDirname = URL(fileURLWithPath: project.dir).lastPathComponent
        } else {
            projectDirname = managedProjectStorageDirectoryName(seed: project.id, preferredName: project.name)
        }
        return workspaceRootDirectory().appending(path: projectDirname, directoryHint: .isDirectory)
    }

    func gitProjectImportPlan(gitURL: String) throws -> GitProjectImportPlan {
        let trimmedURL = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { throw WorkspaceError.invalidArgument(message: "Git repository URL is required.") }
        let inferredName = inferredProjectName(from: trimmedURL)
        let storageHash = managedStorageHash(namespace: "git", source: trimmedURL)
        let projectName = sanitizeDirname(inferredName, fallback: "project")
        let projectDirname = managedProjectStorageDirectoryName(seed: storageHash, preferredName: projectName)
        let destination = repositoriesRootDirectory().appending(path: projectDirname, directoryHint: .isDirectory)
        let normalizedDestination = normalizePathPreservingLeaf(destination.path)
        let project = ProjectRecord(id: UUID().uuidString, name: projectName, dir: normalizedDestination, isGitRepo: true, defaultBranch: nil)
        return GitProjectImportPlan(gitURL: trimmedURL, project: project, destination: destination)
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

    func removeReplaceableManagedDirectory(_ candidate: ManagedDirectoryReplacementCandidate) throws {
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

    func validateManagedDirectoryIsUnowned(path: String) throws {
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

    func isMissingWorktreeError(_ error: Error) -> Bool {
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

    private func managedProjectStorageDirectoryName(seed: String, preferredName: String) -> String {
        let sanitizedName = sanitizeDirname(preferredName, fallback: "project")
        let hashSuffix = String(seed.lowercased().prefix(16))
        let maxNameLength = max(1, 255 - hashSuffix.count - 1)
        let truncatedName = String(sanitizedName.prefix(maxNameLength))
        return "\(truncatedName)-\(hashSuffix)"
    }

    private func managedStorageHash(namespace: String, source: String) -> String {
        let data = Data("\(namespace)\u{0}\(source)".utf8)
        #if canImport(CryptoKit)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in data {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return String(format: "%016llx", hash)
        #endif
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

    func removeManagedProjectDirectoryIfNeeded(project: ProjectRecord) throws {
        guard project.isGitRepo, isManagedRepositoryDirectory(path: project.dir) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.dir, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        try FileManager.default.removeItem(atPath: project.dir)
    }

    func removePreparedManagedProjectDirectoryIfUnowned(project: ProjectRecord) throws {
        guard project.isGitRepo, isManagedRepositoryDirectory(path: project.dir) else { return }
        try removePreparedManagedDirectoryIfUnowned(path: project.dir)
    }

    func removePreparedManagedDirectoryIfUnowned(path: String) throws {
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

    func preferredImportedDefaultBranch(path: String) throws -> String {
        if git.branchExists(path: path, branch: "main") { return "main" }
        if git.branchExists(path: path, branch: "master") { return "master" }
        throw WorkspaceError.invalidArgument(message: "Imported git repository must contain a main or master branch.")
    }

    func isManagedWorkspacesDirectory(path: String, allowEqual: Bool = false) -> Bool {
        isPath(path, inside: workspaceRootDirectory().path, allowEqual: allowEqual)
    }

    func isManagedWorkspaceEntryPath(_ path: String, allowEqual: Bool = false) -> Bool {
        isPathPreservingSymlinks(path, inside: workspaceRootDirectory().path, allowEqual: allowEqual)
    }

    private func removeManagedWorkspaceDirectoryIfNeeded(path: String) throws {
        let normalizedPath = normalizePath(path)
        guard isManagedWorkspacesDirectory(path: normalizedPath) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        try FileManager.default.removeItem(atPath: normalizedPath)
    }

    func isPath(_ path: String, inside rootPath: String, allowEqual: Bool = false) -> Bool {
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

    func isPathPreservingSymlinks(_ path: String, inside rootPath: String, allowEqual: Bool = false) -> Bool {
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

    enum RemoteAgentSignalType: String {
        case `init` = "init"
        case start = "start"
        case waiting = "waiting"
        case done = "done"
        case exit = "exit"

        var status: AgentWindowStatus {
            switch self {
            case .`init`: .idle
            case .start: .spinning
            case .waiting: .waiting
            case .done: .done
            case .exit: .idle
            }
        }

        var establishesAgentFromEvidence: Bool {
            switch self {
            case .start, .waiting, .done: true
            case .`init`, .exit: false
            }
        }
    }

    public func recoverMissingBrowserSession(workspaceID: String, targetURL: String) throws {
        try requireWorkspaceSetupSucceeded(workspaceID: workspaceID)
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let sessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        guard !sessions.isEmpty else { throw WorkspaceError.invalidArgument(message: "No browser sessions are configured for this workspace.") }
        guard chrome.isAvailable() else { throw WorkspaceError.dependencyMissing(message: "Google Chrome is required for browser sessions.") }

        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let runtimePlan = try workspaceRuntimePlan(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) },
            runtimeManifest: runtimePlan.manifest)
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

    func markWorkspaceRunningIfNeeded(_ workspace: WorkspaceRecord) throws {
        guard !workspace.isRunning else { return }
        let launchedAt = workspace.lastLaunchedAt ?? nowISO8601()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: launchedAt)
    }

    func markWorkspaceRunningIfNeeded(workspaceID: String) throws {
        guard let workspace = try store.workspace(id: workspaceID) else { return }
        try markWorkspaceRunningIfNeeded(workspace)
    }

    func clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: String) throws {
        guard try !hasTrackedRuntimeIndicators(workspaceID: workspaceID), let workspace = try store.workspace(id: workspaceID) else { return }
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: false, launchedAt: workspace.lastLaunchedAt)
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

    func safeFilename(_ raw: String) -> String {
        raw.map { char in
            if char.isLetter || char.isNumber { return char }
            return "_"
        }.reduce("") { $0 + String($1) }
    }

}
