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
    /// `(title, body, subtitle)`. Delivers a user-facing notification. The daemon
    /// cannot show OS notifications (no app bundle), so it installs a process-wide
    /// override that forwards to the client instead of delivering directly.
    public typealias NotificationDeliverer = @Sendable (String, String, String?) -> Void
    /// `(subscriberTerminalSessionID, line)`. Submits a rendered coding-agent notification line into a
    /// subscriber terminal. The device-runtime reconcilers build plain orchestrators on a detached task
    /// and cannot reach the daemon's terminal-send path directly, so the daemon installs a process-wide
    /// override that routes to the same send chokepoint its request-path notification engine uses.
    public typealias AgentNotificationLineSubmitter = @Sendable (String, String) throws -> Void
    /// Reports whether the owning daemon is mid exec-in-place handoff. Installed process-wide so every
    /// transient daemon orchestrator (discovery scans, reconcilers, Device API handlers) consults the
    /// same handoff flag the profile orchestrator does, not just the one built by `makeProfileOrchestrator`.
    public typealias DaemonHandoffInProgressPredicate = @Sendable () -> Bool

    public static let terminalTrackingIDEnvVar = "SPACES_TERMINAL_TRACKING_ID"
    #if canImport(UserNotifications)
        private static let notificationAuthorizationCache = LockedBox<UNAuthorizationStatus?>(nil)
    #endif
    private static let builtInTerminalSessionLauncherOverrideStore = LockedBox<BuiltInTerminalSessionLauncher?>(nil)
    private static let builtInTerminalSessionTerminatorOverrideStore = LockedBox<BuiltInTerminalSessionTerminator?>(nil)
    private static let notificationDelivererOverrideStore = LockedBox<NotificationDeliverer?>(nil)
    static let agentNotificationLineSubmitterOverrideStore = LockedBox<AgentNotificationLineSubmitter?>(nil)
    private static let daemonHandoffInProgressOverrideStore = LockedBox<DaemonHandoffInProgressPredicate?>(nil)

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

    public struct PreparedGitProjectImport: Codable, Sendable {
        public let project: ProjectRecord
        public let defaultWorkspace: WorkspaceRecord
        public let importedDocument: SpacesYAMLDocument?

        public init(project: ProjectRecord, defaultWorkspace: WorkspaceRecord, importedDocument: SpacesYAMLDocument?) {
            self.project = project
            self.defaultWorkspace = defaultWorkspace
            self.importedDocument = importedDocument
        }
    }

    /// The result of loading `spaces.yaml` for the add-project preview without cloning the repo.
    /// `project` carries the imported config applied onto a base record; `replacementCandidates`
    /// reports managed directories that a later Create would replace, detected from the local
    /// filesystem (no clone required).
    public struct GitProjectPreview: Sendable {
        public let project: ProjectRecord
        public let replacementCandidates: [ManagedDirectoryReplacementCandidate]
        /// Whether a `spaces.yaml` was found on the repository's default branch. `false` means the
        /// returned config is empty because the repo has no `spaces.yaml`, not because it was empty.
        public let spacesYAMLFound: Bool

        public init(project: ProjectRecord, replacementCandidates: [ManagedDirectoryReplacementCandidate], spacesYAMLFound: Bool) {
            self.project = project
            self.replacementCandidates = replacementCandidates
            self.spacesYAMLFound = spacesYAMLFound
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

    /// Installs a process-wide notification deliverer used when an orchestrator is
    /// created without an explicit one. The daemon sets this to forward notifications
    /// to the client, since a bundle-less daemon cannot post OS notifications.
    public static func setProcessWideNotificationDeliverer(_ deliverer: NotificationDeliverer?) { notificationDelivererOverrideStore.set(deliverer) }

    /// Installs a process-wide submitter for coding-agent notification lines. The daemon sets this to
    /// the same terminal-send chokepoint its request-path notification engine uses, so a child agent
    /// whose exit is detected by reconciliation (no session-end hook fired) notifies its subscribers
    /// identically to the hook-signaled exit path.
    public static func setProcessWideAgentNotificationLineSubmitter(_ submitter: AgentNotificationLineSubmitter?) {
        agentNotificationLineSubmitterOverrideStore.set(submitter)
    }

    /// Installs a process-wide handoff predicate consumed by every orchestrator built without an explicit
    /// one. The daemon sets this so its transient orchestrators (the worktree-discovery scan, the runtime
    /// reconcilers, the Device API handlers) veto `stopWorkspaceUnlocked`'s destructive row deletes during
    /// an exec-in-place handoff, matching the profile orchestrator. See `daemonHandoffInProgress`'s doc.
    public static func setProcessWideDaemonHandoffInProgress(_ predicate: DaemonHandoffInProgressPredicate?) {
        daemonHandoffInProgressOverrideStore.set(predicate)
    }

    /// Builds the notification engine the device-runtime reconcilers use to tell subscribers a coding
    /// agent exited when reconciliation — not a hook — detected the exit. Delivery routes through the
    /// process-wide submitter the daemon installs; with none installed (non-daemon callers, tests that
    /// build an engine directly) delivery throws, which the engine reads as a vanished subscriber and
    /// which is unreachable when the agent has no subscribers. The `(<kind>)` parenthetical reuses the
    /// same runtime-state resolution `agent list` uses.
    func makeAgentNotificationEngine() -> AgentNotificationEngine {
        let submitter = Self.agentNotificationLineSubmitterOverrideStore.get()
        return AgentNotificationEngine(
            store: store,
            deliver: { sessionID, line in
                guard let submitter else { throw WorkspaceError.invalidArgument(message: "No agent notification submitter is configured.") }
                try submitter(sessionID, line)
            }, resolveAgentKind: { [self] agent in agent.terminalTrackingID.flatMap { agentRuntimeKind(terminalSessionID: $0) } },
            logError: { Self.writeStandardError($0) })
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

    struct SpacesTerminalSessionHandle {
        let sessionID: String
        let childPID: Int?
        let outputPath: String
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
        case sessionRequest
        case unavailable
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
    let currentDate: () -> Date
    let notificationDeliverer: (String, String, String?) -> Void
    let builtInTerminalWindowOpener: BuiltInTerminalWindowOpener
    let builtInTerminalWindowFocuser: BuiltInTerminalWindowFocuser
    let builtInTerminalWindowCloser: BuiltInTerminalWindowCloser
    let builtInTerminalSessionTerminator: BuiltInTerminalSessionTerminator
    let builtInTerminalSessionLauncher: BuiltInTerminalSessionLauncher
    /// Reports whether the owning daemon is mid exec-in-place handoff. During a handoff the daemon's
    /// terminal terminator no-ops (live sessions are quiesced and carried across the exec, not killed),
    /// so a destructive workspace operation that deleted its process/window/agent rows would leave the
    /// replacement daemon adopting a still-live terminal whose records were removed. `stopWorkspaceUnlocked`
    /// consults this at its row-mutation boundary and throws `WorkspaceError.daemonHandoffInProgress` so the
    /// terminal-side effect and the database mutation stay consistent — neither is applied when a handoff
    /// intervenes. When no explicit predicate is passed, resolves to the process-wide override the daemon
    /// installs (so its transient orchestrators — discovery scans, reconcilers, Device API handlers — share
    /// the profile orchestrator's handoff gate) and otherwise defaults to `{ false }` for every non-daemon
    /// orchestrator (GUI, CLI, tests), which never hands off.
    let daemonHandoffInProgress: @Sendable () -> Bool
    private let projectsRootDirectoryURL: URL?
    private let workspacesRootDirectoryURL: URL?
    private let workspaceLifecycleGate = PerKeyGate()
    let workspaceSetupGate = PerKeyGate()

    public init(
        store: SQLiteStore, projectsRootDirectory: URL? = nil, workspacesRootDirectory: URL? = nil, git: GitClient = .init(),
        notificationDeliverer: ((String, String, String?) -> Void)? = nil, builtInTerminalWindowOpener: BuiltInTerminalWindowOpener? = nil,
        builtInTerminalWindowFocuser: BuiltInTerminalWindowFocuser? = nil, builtInTerminalWindowCloser: BuiltInTerminalWindowCloser? = nil,
        builtInTerminalSessionTerminator: BuiltInTerminalSessionTerminator? = nil,
        builtInTerminalSessionLauncher: BuiltInTerminalSessionLauncher? = nil, daemonHandoffInProgress: (@Sendable () -> Bool)? = nil,
        currentDate: @escaping () -> Date = Date.init
    ) {
        self.store = store
        projectsRootDirectoryURL = projectsRootDirectory
        self.git = git
        self.daemonHandoffInProgress = daemonHandoffInProgress ?? Self.daemonHandoffInProgressOverrideStore.get() ?? { false }
        self.workspacesRootDirectoryURL = workspacesRootDirectory
        self.notificationDeliverer = notificationDeliverer ?? Self.notificationDelivererOverrideStore.get() ?? Self.deliverUserNotification
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

    public func project(id: String) throws -> ProjectRecord? { try store.project(id: id) }

    public func project(dir: String) throws -> ProjectRecord? { try store.project(dir: dir) }

    public func listWorkspaces(projectID: String, includeArchived: Bool = false) throws -> [WorkspaceSummary] {
        let records = try store.workspaces(projectID: projectID, includeArchived: includeArchived)
        return records.map {
            WorkspaceSummary(
                id: $0.id, branch: $0.branch, baseBranch: $0.baseBranch, dir: $0.dir, isRunning: $0.isRunning, isArchived: $0.isArchived,
                isHidden: $0.isHidden, isDefault: $0.isDefault, notes: $0.notes)
        }
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
            runtimeManifest: workspaceRuntimeManifest(project: project, workspace: workspace, assignedPorts: assignedPorts))
        return resolveBrowserSessions(sessions, env: env).map { resolved in BrowserSession(name: resolved.session.name, url: resolved.prefix) }
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
        existing.ports = normalizeServiceDefinitionIDs(previous: previousPorts, updated: existing.ports)
        existing.ports = try normalizedServiceDefinitions(existing.ports)
        existing.processes = normalizeProcessTemplateIDs(previous: previousProcesses, updated: existing.processes)
        existing.agentLaunchers = normalizeAgentLauncherIDs(previous: previousAgentLaunchers, updated: existing.agentLaunchers)
        try validateProcessTemplates(existing.processes)
        try validateWorkspaceFocusNames(
            workspaceID: workspace.id, processes: existing.processes, browserSessions: existing.browserSessions,
            agentLaunchers: existing.agentLaunchers, agentWindows: try store.agentWindows(workspaceID: workspace.id))
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: existing.stopScript)
        try store.setWorkspaceServiceDefinitions(workspaceID: workspace.id, definitions: existing.ports)
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

    public func updateWorkspaceMetadata(workspaceID: String, branch: String? = nil, directoryName: String? = nil, notes: String?? = nil) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        var updatedBranch = workspace.branch
        var updatedDirname = workspace.dirname
        var updatedNotes = workspace.notes
        var didChange = false

        if let branch {
            guard project.isGitRepo else { throw WorkspaceError.invalidArgument(message: "Branch can only be updated for git projects.") }
            let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBranch.isEmpty else { throw WorkspaceError.invalidArgument(message: "Workspace branch is required.") }
            if let currentBranch = workspace.branch, isProtectedBranchName(currentBranch), trimmedBranch != currentBranch {
                throw WorkspaceError.invalidArgument(message: "Protected branches main/master cannot be renamed.")
            }
            if trimmedBranch != workspace.branch {
                if let existing = try workspaceForBranch(projectID: workspace.projectID, branch: trimmedBranch), existing.id != workspace.id {
                    throw WorkspaceError.invalidArgument(message: "Branch '\(trimmedBranch)' is already used by workspace '\(existing.displayName)'.")
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
            id: workspace.id, projectID: workspace.projectID, dir: workspace.dir, dirname: updatedDirname, branch: updatedBranch,
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
        projectID: String, branch: String? = nil, baseBranch: String? = nil, directoryName: String? = nil, runSetupScript: Bool = true,
        allowRemoteBranchLookup: Bool = true, allowExistingBranchReuse: Bool = false, replaceExistingManagedDirectory: Bool = false
    ) throws -> WorkspaceRecord {
        guard let project = try store.project(id: projectID) else { throw WorkspaceError.missingProject(dir: projectID) }
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
            if let existing = try workspaceForBranch(projectID: projectID, branch: branchName) {
                if existing.isArchived {
                    guard allowExistingBranchReuse else {
                        throw WorkspaceError.invalidArgument(
                            message: "Branch '\(branchName)' already exists. Choose it from Existing branch or enter a different new branch name.")
                    }
                } else {
                    throw WorkspaceError.invalidArgument(message: "Branch '\(branchName)' is already used by workspace '\(existing.displayName)'.")
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
                    path: project.dir, worktreePath: revivedDir, branch: branchName, baseBranch: resolvedBaseBranch,
                    allowRemoteBranchLookup: allowRemoteBranchLookup)
            }
            revivedBranch = branchName
            let revived = WorkspaceRecord(
                id: existing.id, projectID: project.id, dir: revivedDir, dirname: revivedDirname, branch: revivedBranch,
                baseBranch: existing.baseBranch ?? resolvedBaseBranch, isDefault: false, isArchived: false, isHidden: existing.isHidden,
                isRunning: false, lastLaunchedAt: nil)
            try store.upsert(workspace: revived)
            try seedWorkspaceSettings(project: project, workspace: revived)
            try initializeWorkspaceRuntime(project: project, workspace: revived, runSetupScript: runSetupScript)
            return revived
        }
        if !project.isGitRepo, let existingActive = try store.workspace(dir: project.dir), !existingActive.isArchived {
            // A non-git project owns exactly one workspace (the project directory). If an
            // active one already exists, return it rather than inserting a duplicate that
            // would be indistinguishable by display name.
            return existingActive
        }
        if !project.isGitRepo, let existing = try archivedWorkspace(projectID: projectID, dir: project.dir) {
            let revived = WorkspaceRecord(
                id: existing.id, projectID: project.id, dir: project.dir, dirname: existing.dirname, branch: nil, baseBranch: nil, isDefault: false,
                isArchived: false, isHidden: existing.isHidden, isRunning: false, lastLaunchedAt: nil)
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
            id: UUID().uuidString, projectID: project.id, dir: workspaceDir, dirname: workspaceDirname, branch: workspaceBranch,
            baseBranch: resolvedBaseBranch, isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        try seedWorkspaceSettings(project: project, workspace: workspace)
        try initializeWorkspaceRuntime(project: project, workspace: workspace, runSetupScript: runSetupScript)

        return workspace
    }

    public func createWorkspaceOnDevice(
        projectID: String, branch: String, baseBranch: String? = nil, directoryName: String? = nil, notes: String? = nil, runSetupScript: Bool = true,
        allowRemoteBranchLookup: Bool = true, allowExistingBranchReuse: Bool = false
    ) throws -> WorkspaceRecord {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { throw WorkspaceError.invalidArgument(message: "Branch name is required for git projects.") }
        var workspace = try createWorkspace(
            projectID: projectID, branch: trimmedBranch, baseBranch: baseBranch, directoryName: directoryName, runSetupScript: runSetupScript,
            allowRemoteBranchLookup: allowRemoteBranchLookup, allowExistingBranchReuse: allowExistingBranchReuse)
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

    public func createWorkspaceFromWorktree(worktreePath: String) throws -> WorkspaceRecord {
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
                    message: "Workspace already exists but is archived: \(existing.displayName). Unarchive it or use a different worktree.")
            }
            throw WorkspaceError.invalidArgument(message: "Workspace already exists: \(existing.displayName)")
        }
        let branchOutput = try git.runGitAndCapture(["-C", normalizedWorktreePath, "rev-parse", "--abbrev-ref", "HEAD"])
        let branch = branchOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = try workspaceForBranch(projectID: project.id, branch: branch) {
            if existing.isArchived {
                throw WorkspaceError.invalidArgument(
                    message:
                        "Workspace already exists for archived branch '\(branch)': \(existing.displayName). Unarchive it or use a different worktree."
                )
            }
            throw WorkspaceError.invalidArgument(message: "Workspace already exists for branch '\(branch)': \(existing.displayName)")
        }
        let dirname = URL(fileURLWithPath: normalizedWorktreePath).lastPathComponent
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, dir: normalizedWorktreePath, dirname: dirname, branch: branch, isDefault: false,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
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
                        id: workspace.id, projectID: workspace.projectID, dir: workspace.dir, dirname: workspace.dirname, branch: worktree.branchName,
                        baseBranch: workspace.baseBranch, isDefault: workspace.isDefault, isArchived: workspace.isArchived,
                        isHidden: workspace.isHidden, isRunning: workspace.isRunning, lastLaunchedAt: workspace.lastLaunchedAt, notes: workspace.notes
                    )
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
                    id: UUID().uuidString, projectID: project.id, dir: normalizedPath,
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
        try store.workspaces(projectID: projectID, includeArchived: true).first { $0.branch == branch }
    }

    private func archivedWorkspace(projectID: String, branch: String) throws -> WorkspaceRecord? {
        try store.workspaces(projectID: projectID, includeArchived: true).first { $0.branch == branch && $0.isArchived }
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
        let portDefinitions = try store.workspaceServiceDefinitions(workspaceID: workspace.id)
        let ports = try store.workspacePorts(workspaceID: workspace.id)
        if ports.count != portDefinitions.count {
            let portRange = try store.appConfig().portRange
            _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, definitions: portDefinitions, range: portRange)
        } else {
            try PortAllocator(store: store).reserveExistingPorts(workspaceID: workspace.id)
        }

        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let runtimeManifest = workspaceRuntimeManifest(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) }, runtimeManifest: runtimeManifest
        )
        let shouldReleaseReservedPortsForLaunch = !assignedPorts.isEmpty
        if shouldReleaseReservedPortsForLaunch {
            // Workspace port assignments remain pinned in the store until archive, but placeholder
            // reservation sockets exist only while the workspace is stopped. Once any runtime starts,
            // users resolve conflicts manually if another process claims an assigned port.
            releaseReservedPortsForRuntimeStart(workspaceID: workspace.id)
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
        var seenKeys = Set<String>()
        let uniqueWindows = newWindows.filter { window in
            let key = windowTrackingKey(window)
            if seenKeys.contains(key) { return false }
            seenKeys.insert(key)
            return true
        }
        for window in uniqueWindows {
            let stored = WindowRecord(
                id: window.id, workspaceID: window.workspaceID, app: window.app, name: window.name, detail: window.detail,
                targetURL: window.targetURL, terminalTrackingID: window.terminalTrackingID, role: window.role, orderIndex: index,
                lastSeenAt: window.lastSeenAt)
            index += 1
            try store.upsert(window: stored)
        }

        try markWorkspaceRunning(workspace, launchedAt: nowISO8601())
        shouldRestoreReservedPorts = false
    }

    @discardableResult public func stopWorkspace(workspaceID: String) throws -> WorkspaceStopOutcome {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) { try stopWorkspaceUnlocked(workspaceID: workspaceID) }
    }

    private func stopWorkspaceUnlocked(workspaceID: String, waitForTerminalExit: Bool = true) throws -> WorkspaceStopOutcome {
        // Refuse a stop that races a daemon handoff before touching anything: the daemon's terminator
        // no-ops during handoff (sessions are quiesced and carried across the exec), so proceeding would
        // delete the workspace's rows while its terminals stay live. Rejecting here keeps both the
        // terminals and their records intact for the replacement daemon to resume.
        guard !daemonHandoffInProgress() else { throw WorkspaceError.daemonHandoffInProgress }
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let windows = try indexedWorkspaceWindows(workspaceID: workspace.id)
        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let runtimeManifest = workspaceRuntimeManifest(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) }, runtimeManifest: runtimeManifest
        )
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        let processes = try store.runningProcesses(workspaceID: workspace.id)
        var closedBuiltInTerminalSessionIDs = Set<String>()
        var skippedStopScriptBecauseWorkspaceDirectoryMissing = false
        for process in processes {
            if isManagedTerminalApp(process.terminalApp) {
                if let sessionID = process.terminalTrackingID, !sessionID.isEmpty {
                    terminateBuiltInTerminalSession(sessionID)
                    closedBuiltInTerminalSessionIDs.insert(sessionID)
                }
            } else if let pid = resolvedRuntimePID(for: process) {
                terminateProcessGroup(pid: pid)
            }
        }
        let workspaceAgentWindows = try store.agentWindows(workspaceID: workspace.id)
        for agent in workspaceAgentWindows {
            if let sessionID = agent.terminalTrackingID, !sessionID.isEmpty {
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
        // Browser tabs are client-owned (the app tracks each session's Chrome window) and
        // are never closed by the daemon on stop; only Spaces-managed terminal sessions are
        // terminated by session id here.
        for window in windows where window.roleValue == .terminal && isManagedTerminalApp(window.app) {
            guard let sessionID = normalizedTerminalSessionID(window.terminalTrackingID) else { continue }
            if !closedBuiltInTerminalSessionIDs.contains(sessionID) {
                terminateBuiltInTerminalSession(sessionID)
                closedBuiltInTerminalSessionIDs.insert(sessionID)
            }
        }
        // CLI-created shells are workspace-owned by launch metadata even when no runtime-target row exists.
        for sessionID in try liveAdHocBuiltInTerminalSessionIDs(workspaceID: workspace.id) {
            if !closedBuiltInTerminalSessionIDs.contains(sessionID) {
                terminateBuiltInTerminalSession(sessionID)
                closedBuiltInTerminalSessionIDs.insert(sessionID)
            }
        }
        // Re-check at the row-mutation boundary: a handoff that began after the entry guard (while the
        // terminate loop above was running) would have silently no-op'd the not-yet-terminated sessions.
        // Aborting before the deletes below prevents the dangerous divergence where rows are erased while
        // their terminals survive into the replacement daemon. Sessions already terminated before the
        // handoff started keep their (now-stale) rows, which normal stale-session recovery reconciles; no
        // live terminal is ever orphaned from its records.
        guard !daemonHandoffInProgress() else { throw WorkspaceError.daemonHandoffInProgress }
        if waitForTerminalExit { waitForBuiltInTerminalSessionsToExit(closedBuiltInTerminalSessionIDs) }
        try store.deleteRunningProcesses(workspaceID: workspace.id)
        try store.deleteWindows(workspaceID: workspace.id)
        // Stopping a workspace ends every coding agent in it. A subscriber watching one of these agents may
        // live in ANOTHER workspace, so each is destroyed through the finalization chokepoint (its terminal
        // was already terminated above): the child's subscribers are told it exited before its row is
        // deleted, and the stopped terminal's own watch state is torn down.
        for agent in workspaceAgentWindows { try finalizeAgentRow(agent, reason: .destroyed(terminateTerminalSession: false)) }
        try markWorkspaceStopped(workspace)
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
        // `stopWorkspaceUnlocked` already deleted this workspace's agent rows (notifying subscribers and
        // tearing down watch state) under the same lifecycle lock, so archive does not repeat the delete.
        _ = try stopWorkspaceUnlocked(workspaceID: workspaceID, waitForTerminalExit: false)
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
        let trackedBrowserTargets = Set(trackedWindows.filter { $0.roleValue == .browser }.compactMap(\.targetURL).filter { !$0.isEmpty })
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
        try workspaceLifecycleGate.withKey(
            workspaceID, busyError: { WorkspaceError.invalidArgument(message: "Workspace action is already in progress.") }, operation: operation)
    }

    #if canImport(UserNotifications)
        public static func deliverUserNotification(title: String, body: String, subtitle: String? = nil) {
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
            let statusBox = LockedBox<UNAuthorizationStatus?>(nil)
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

    #else
        public static func deliverUserNotification(title _: String, body _: String, subtitle _: String? = nil) {}

        public static func prepareUserNotificationAuthorization() {}
    #endif

    public func windows(workspaceID: String) throws -> [WindowRecord] { try indexedWorkspaceWindows(workspaceID: workspaceID) }

    public struct RefreshResult: Sendable {
        public let didMutateDB: Bool
        public let trackedWindowCounts: [String: Int]
    }

    @discardableResult public func refreshWorkspaceWindows(workspaceID: String) throws -> Bool {
        _ = try indexedWorkspaceWindows(workspaceID: workspaceID)
        let pruned = try pruneMissingWindows(workspaceID: workspaceID)
        return pruned > 0
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
        let trimmedCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawCommand = (trimmedCommand?.isEmpty == false) ? command! : interactiveShellCommand(cwd: workspace.dir)
        return try launchWorkspaceCommandSession(
            project: project, workspace: workspace, title: title, rawCommand: rawCommand, kind: .shell,
            defaultTitle: try generatedAdHocTerminalWindowName(workspaceID: workspace.id))
    }

    /// Creates an ad-hoc coding-agent terminal session. Mirrors `createWorkspaceTerminalSession` but
    /// launches with `kind: .agent` and a required command. The `.agent` kind is load-bearing: it is
    /// the deterministic label evidence the daemon's signal chokepoint needs to accept a non-`init`
    /// first signal, so a coding agent (e.g. Codex) that emits `working` before `init` still registers.
    /// The default title is the matched coding agent's display name (or the command's executable
    /// basename when no supported agent matches — spawn's hook gate has already ensured one does).
    @discardableResult public func createWorkspaceAgentSession(workspaceID: String, command: String, title: String?) throws
        -> TerminalServiceSessionSummary
    {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isArchived else { throw WorkspaceError.invalidArgument(message: "Workspace is archived.") }
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { throw WorkspaceError.invalidArgument(message: "Agent command is required.") }
        let defaultTitle =
            SupportedCodingAgentHook.matching(command: command)?.displayName
            ?? (SupportedCodingAgentHook.executableToken(inCommand: command).map { ($0 as NSString).lastPathComponent } ?? "Agent")
        return try launchWorkspaceCommandSession(
            project: project, workspace: workspace, title: title, rawCommand: command, kind: .agent, defaultTitle: defaultTitle)
    }

    /// Shared launch path for ad-hoc command and agent sessions: builds the workspace environment,
    /// prefixes the shell command, persists the tracked terminal window, and marks the workspace
    /// running. The only per-caller differences are the launch `kind` and the fallback title.
    @discardableResult private func launchWorkspaceCommandSession(
        project: ProjectRecord, workspace: WorkspaceRecord, title: String?, rawCommand: String, kind: TerminalSessionKind, defaultTitle: String
    ) throws -> TerminalServiceSessionSummary {
        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let sessionID = UUID().uuidString
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionTitle = (trimmedTitle?.isEmpty == false) ? trimmedTitle! : defaultTitle
        let runtimeManifest = workspaceRuntimeManifest(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = try terminalLaunchEnvironment(
            base: buildWorkspaceEnv(
                project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) },
                runtimeManifest: runtimeManifest
            ).merging([Self.terminalTrackingIDEnvVar: sessionID]) { _, new in new }, includeInheritedPath: false, includeProfileEnvironment: true)
        let shellPath = terminalShellPathOverride() ?? "/bin/zsh"
        let launchCommand = commandPrefixedWithShellEnvironment(rawCommand, env: env)
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: sessionTitle, workingDirectory: workspace.dir,
            shell: shellPath, command: launchCommand, createdAt: nowISO8601(), workspaceID: workspace.id, kind: kind)

        let session = try builtInTerminalSessionLauncher(launchConfiguration)
        let windowRecordID = UUID().uuidString
        do {
            let existing = try store.windows(workspaceID: workspace.id)
            try store.upsert(
                window: WindowRecord(
                    id: windowRecordID, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: sessionTitle, detail: nil, targetURL: nil,
                    terminalTrackingID: session.id, role: "terminal",
                    orderIndex: Self.nextWindowOrderIndex(existing: existing, role: "terminal", orderOffset: 200), lastSeenAt: nowISO8601()))
            try markWorkspaceRunningIfNeeded(workspace)
        } catch {
            terminateBuiltInTerminalSession(session.id)
            try? store.deleteWindow(id: windowRecordID)
            throw error
        }
        return session
    }

    /// Resolves the workspace `spaces terminal command` should target: the explicit
    /// `--workspace` id when given, else the deepest unarchived workspace whose directory
    /// contains `cwd` (same containment rule as `workspaceForBuiltInTerminalSession`'s
    /// fallback). Errors clearly when neither resolves, instead of falling back to a
    /// workspace-less session.
    public func resolveWorkspaceIDForTerminalCommand(explicitWorkspaceID: String?, cwd: String) throws -> String {
        if let explicitWorkspaceID = explicitWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitWorkspaceID.isEmpty {
            return explicitWorkspaceID
        }
        let workspaces = try store.projects().flatMap { project in try store.workspaces(projectID: project.id, includeArchived: false) }
        guard
            let matched = workspaces.filter({ isPath(cwd, inside: $0.dir, allowEqual: true) }).max(by: {
                normalizePath($0.dir).count < normalizePath($1.dir).count
            })
        else { throw WorkspaceError.invalidArgument(message: "Current directory is not inside a Spaces workspace.") }
        return matched.id
    }

    public func reserveWorkspaceTerminalLaunch(workspaceID: String) throws -> WorkspaceTerminalLaunchReservation {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isArchived else { throw WorkspaceError.invalidArgument(message: "Workspace is archived.") }
        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspaceID)
        let sessionID = UUID().uuidString
        let runtimeManifest = workspaceRuntimeManifest(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = try terminalLaunchEnvironment(
            base: buildWorkspaceEnv(
                project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) },
                runtimeManifest: runtimeManifest
            ).merging([Self.terminalTrackingIDEnvVar: sessionID]) { _, new in new }, includeInheritedPath: false, includeProfileEnvironment: true)
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
                // No title: nothing has run in this session yet, so it has reported nothing. The
                // generated name lives in the launch configuration, which is where readers take it from.
                state: .starting, updatedAt: createdAt, workingDirectory: workingDirectory), paths: paths)
        _ = FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
        _ = FileManager.default.createFile(atPath: paths.serviceLogPath, contents: nil)
        let existing = try store.windows(workspaceID: workspace.id)
        let nextOrder = Self.nextWindowOrderIndex(existing: existing, role: "terminal", orderOffset: 200)
        let windowRecordID = UUID().uuidString
        let appName = TerminalHost.spaces.appName
        try store.upsert(
            window: WindowRecord(
                id: windowRecordID, workspaceID: workspace.id, app: appName, name: generatedTitle, detail: nil, targetURL: nil,
                terminalTrackingID: sessionID, role: "terminal", orderIndex: nextOrder, lastSeenAt: nowISO8601()))
        try markWorkspaceRunningIfNeeded(workspace)
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
                readinessPolicy: .stableChildPID, sessionID: reservation.sessionID, lifetimePolicy: reservation.launchConfiguration.lifetimePolicy,
                workspaceID: reservation.launchConfiguration.workspaceID, kind: reservation.launchConfiguration.kind)
            if reservation.windowRecordInsertedBeforeLaunch {
                guard try reservedWorkspaceTerminalWindowExists(reservation) else {
                    builtInTerminalSessionTerminator(reservation.sessionID)
                    return session.sessionID
                }
            }
            try store.upsert(
                window: WindowRecord(
                    id: reservation.windowRecordID, workspaceID: reservation.workspaceID, app: reservation.appName, name: reservation.title,
                    detail: nil, targetURL: nil, terminalTrackingID: session.sessionID, role: "terminal", orderIndex: reservation.orderIndex,
                    lastSeenAt: nowISO8601()))
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
                state: .failed, updatedAt: now, exitedAt: now, title: previousRuntimeState?.title,
                workingDirectory: previousRuntimeState?.workingDirectory ?? reservation.launchConfiguration.workingDirectory,
                columns: previousRuntimeState?.columns, rows: previousRuntimeState?.rows, foregroundPID: previousRuntimeState?.foregroundPID,
                foregroundExecutablePath: previousRuntimeState?.foregroundExecutablePath,
                foregroundExecutableName: previousRuntimeState?.foregroundExecutableName, foregroundArgv: previousRuntimeState?.foregroundArgv,
                foregroundDetectedAgentKind: previousRuntimeState?.foregroundDetectedAgentKind,
                foregroundDisplayLabel: previousRuntimeState?.foregroundDisplayLabel,
                foregroundDisplayCommand: previousRuntimeState?.foregroundDisplayCommand, bellAt: previousRuntimeState?.bellAt)
            try? TerminalSessionPersistence.writeRuntimeState(failedState, paths: paths)
            try? TerminalSessionPersistence.detachActiveClients(paths: paths, detachedAt: now)
            try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
            try? FileManager.default.removeItem(atPath: paths.subscriptionSocketPath)
        }
        try? store.deleteWindow(id: reservation.windowRecordID)
        try? clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: reservation.workspaceID)
    }

    private func markWorkspaceRunningIfNeeded(workspaceID: String, launchedAtFallback: String) throws {
        guard let workspace = try store.workspace(id: workspaceID) else { return }
        try markWorkspaceRunningIfNeeded(workspace, launchedAtFallback: launchedAtFallback)
    }

    private func reservedWorkspaceTerminalWindowExists(_ reservation: WorkspaceTerminalLaunchReservation) throws -> Bool {
        try store.windows(workspaceID: reservation.workspaceID).contains { $0.id == reservation.windowRecordID }
    }

    public func workspaceFocusableWindowNames(workspaceID: String) throws -> [String] {
        _ = try resolveWorkspace(id: workspaceID)
        return try focusableWorkspaceTargets(workspaceID: workspaceID).map(\.name)
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
        var matchedProcessIDs = Set<String>()

        var targets: [WorkspaceNavigationTarget] = []

        for window in windows where window.roleValue == .browser {
            let isAgentClaimedWindow = terminalTargetID(window: window).map(agentTerminalIDs.contains) ?? false
            guard !isAgentClaimedWindow else { continue }
            targets.append(.browser(window))
        }

        for window in windows where window.roleValue != .browser {
            let windowTerminalID = terminalTargetID(window: window)
            let windowProcesses: [RunningProcessRecord]
            if window.roleValue == .terminal, let windowTerminalID, let matchedByTerminalID = processesByTerminalID[windowTerminalID],
                !matchedByTerminalID.isEmpty
            {
                windowProcesses = matchedByTerminalID
            } else {
                windowProcesses = []
            }
            let isAgentClaimedWindow = terminalTargetID(window: window).map(agentTerminalIDs.contains) ?? false
            let nonAgentWindowProcesses = windowProcesses.filter { process in
                guard let terminalID = terminalTargetID(process: process) else { return true }
                return !agentTerminalIDs.contains(terminalID)
            }
            if window.roleValue == .terminal, !nonAgentWindowProcesses.isEmpty {
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

    func validateUniqueConfiguredFocusNames(processes: [ProcessTemplate], browserSessions: [BrowserSession], agentLaunchers: [AgentLauncher]) throws {
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
                    id: existing.id, projectID: project.id, dir: existing.dir, dirname: existing.dirname, branch: existing.branch,
                    baseBranch: existing.baseBranch, isDefault: true, isArchived: false, isHidden: existing.isHidden, isRunning: existing.isRunning,
                    lastLaunchedAt: existing.lastLaunchedAt)
                try store.upsert(workspace: revived)
            }
            return
        }
        let workspace = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, dir: project.dir, dirname: nil, branch: project.defaultBranch,
            baseBranch: project.defaultBranch, isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspace)
        try seedWorkspaceSettings(project: project, workspace: workspace)
        let appConfig = try store.appConfig()
        let portDefinitions = try store.workspaceServiceDefinitions(workspaceID: workspace.id)
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
                    ports: try store.workspaceServiceDefinitions(workspaceID: workspace.id),
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
        try store.setWorkspaceServiceDefinitions(workspaceID: snapshot.workspace.id, definitions: settings.ports)
        try store.setWorkspaceProcesses(workspaceID: snapshot.workspace.id, processes: settings.processes)
        try store.setWorkspaceBrowserSessions(workspaceID: snapshot.workspace.id, sessions: settings.browserSessions)
        try store.setWorkspaceAgentLaunchers(workspaceID: snapshot.workspace.id, launchers: settings.agentLaunchers)
        try store.touchWorkspaceSettings(workspaceID: snapshot.workspace.id, updatedAt: nowISO8601())
        try store.setWorkspacePorts(
            workspaceID: snapshot.workspace.id, ports: snapshot.assignedPorts.map { $0.port }, names: snapshot.assignedPorts.map { $0.name },
            definitionIDs: snapshot.assignedPorts.map { $0.definitionID })
        if snapshot.workspace.isArchived {
            PortReserver.shared.releasePorts(workspaceID: snapshot.workspace.id)
        } else {
            try PortAllocator(store: store).reserveExistingPorts(workspaceID: snapshot.workspace.id)
        }
    }

    func seedWorkspaceSettings(project: ProjectRecord, workspace: WorkspaceRecord) throws {
        try validateWorkspaceFocusNames(
            workspaceID: workspace.id, processes: project.processes, browserSessions: project.browserSessions, agentLaunchers: project.agentLaunchers,
            agentWindows: try store.agentWindows(workspaceID: workspace.id))
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: project.stopScript)
        try store.setWorkspaceServiceDefinitions(workspaceID: workspace.id, definitions: project.ports)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: seededWorkspaceProcesses(from: project.processes))
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: project.browserSessions)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: project.agentLaunchers)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: nowISO8601())
    }

    func loadWorkspaceSettings(project: ProjectRecord, workspace: WorkspaceRecord) throws -> WorkspaceSettings? {
        let hasSettings = try store.workspaceSettingsExists(workspaceID: workspace.id)
        if !hasSettings { try seedWorkspaceSettings(project: project, workspace: workspace) }
        let stopScript = try store.workspaceStopScript(workspaceID: workspace.id)
        let ports = try store.workspaceServiceDefinitions(workspaceID: workspace.id)
        let processes = try store.workspaceProcesses(workspaceID: workspace.id)
        let browserSessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        let agentLaunchers = try store.workspaceAgentLaunchers(workspaceID: workspace.id)
        return WorkspaceSettings(
            stopScript: stopScript, ports: ports, processes: processes, browserSessions: browserSessions, agentLaunchers: agentLaunchers)
    }

    private func runScript(_ script: String, cwd: String) throws {
        _ = try Shell.run(["/bin/bash", "-lc", script], cwd: cwd, environment: try workspaceScriptEnvironment())
    }

    /// The environment a workspace script (the stop script) runs with: this process's own environment, minus
    /// anything a process bound to a profile it does not own must not pass on. A stop script is user-authored
    /// shell that commonly calls `spaces`, so a `SPACES_DB_PATH` inherited from the shell that started
    /// `spacese2e --installed-profile stop-workspace` would point those calls at a profile this run is not
    /// serving. Shared with the terminal-session and daemon launch paths through
    /// `SpacesProfile.childProcessEnvironment`, so the exception is defined once.
    ///
    /// The base is `Shell.currentProcessEnvironment()` rather than the raw process environment because that
    /// is what a script launched through `Shell` gets today: PATH merged with the login shell's and Homebrew's
    /// directories, which the version-manager shims a stop script relies on live in.
    func workspaceScriptEnvironment() throws -> [String: String] {
        try SpacesProfile.current().childProcessEnvironment(inheriting: Shell.currentProcessEnvironment())
    }

    private func initializeWorkspaceRuntime(project: ProjectRecord, workspace: WorkspaceRecord, runSetupScript: Bool) throws {
        let appConfig = try store.appConfig()
        let portDefinitions = try store.workspaceServiceDefinitions(workspaceID: workspace.id)
        _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, definitions: portDefinitions, range: appConfig.portRange)
        if runSetupScript {
            try runWorkspaceSetup(project: project, workspace: workspace)
        } else {
            try store.setWorkspaceSetupState(workspaceID: workspace.id, status: .pending, errorMessage: nil, startedAt: nil, finishedAt: nil)
        }
    }

    /// The environment injected into every process and terminal of a workspace: workspace/project
    /// identity variables plus a per-service port/host/URL triple. Public so the Device API overview
    /// can report the authoritative values for the settings dialog to display.
    public func buildWorkspaceEnv(
        project: ProjectRecord, workspace: WorkspaceRecord, namedPorts: [(port: Int, name: String)], runtimeManifest: WorkspaceRuntimeManifest? = nil
    ) -> [String: String] {
        var env: [String: String] = [:]
        // The runtime manifest is the authoritative source of the per-service port variables
        // (SPACES_<SVC>_PORT) and the workspace identity variables (SPACES_WORKSPACE_SLUG / _HOST).
        // Merge it first.
        let manifest =
            runtimeManifest
            ?? SpacesDevicePlanner.runtimeManifest(
                project: project, workspace: workspace,
                namedPorts: namedPorts.map { WorkspaceRuntimePortMapping(id: $0.name, name: $0.name, port: $0.port) })
        env.merge(manifest.processEnvironment) { _, new in new }
        env["SPACES_WORKSPACE_DIR"] = workspace.dir
        env["SPACES_PROJECT_DIR"] = project.dir
        // Browser-facing per-service URL variables so app servers can allowlist the host/origin for
        // CORS or framework host checks. These need the shared router port, which is app configuration
        // available here but not inside the pure planner, so they live only here. The fallback to
        // `AppConfig.defaultRouterPort` yields a stable client-facing identity the client rewrites to
        // its own live Caddy port before navigation.
        let slug = SpacesProfile.workspaceHostSlug(
            branch: workspace.branch, projectName: project.name, isGitRepo: project.isGitRepo, workspaceID: workspace.id)
        let routerPort = (try? store.appConfig().routerPort) ?? AppConfig.defaultRouterPort
        for namedPort in namedPorts {
            let name = namedPort.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            env[ServiceName.urlEnvVar(for: name)] = "http://\(name).\(slug).localhost:\(routerPort)"
        }
        return env
    }

    func workspaceRuntimeManifest(
        project: ProjectRecord, workspace: WorkspaceRecord, assignedPorts: [(definitionID: String, port: Int, name: String)]
    ) -> WorkspaceRuntimeManifest {
        let namedPorts = assignedPorts.map {
            WorkspaceRuntimePortMapping(id: $0.definitionID.isEmpty ? $0.name : $0.definitionID, name: $0.name, port: $0.port)
        }
        return SpacesDevicePlanner.runtimeManifest(project: project, workspace: workspace, namedPorts: namedPorts)
    }

    struct RunningWorkspaceProcessEdit {
        let previous: ProcessTemplate
        let updated: ProcessTemplate
        let previousKey: String
        let updatedKey: String

        var commandChanged: Bool { previous.command != updated.command }
        var keyChanged: Bool { previousKey != updatedKey }
    }

    /// Prunes tracked terminal rows whose Spaces session has ended. Browser windows are
    /// client-owned and never pruned here; terminal liveness is determined entirely by the
    /// session id, so there is no desktop-window enumeration.
    @discardableResult private func pruneMissingWindows(workspaceID: String) throws -> Int {
        let windows = try store.windows(workspaceID: workspaceID)
        let agentWindows = try store.agentWindows(workspaceID: workspaceID)
        var prunedTerminalTrackingKeys = Set<String>()
        var pruned = 0
        for window in windows where window.roleValue != .browser {
            if managedTrackedTerminalWindowIsStillLive(window: window) { continue }
            if window.roleValue == .terminal, let trackingKey = window.terminalTrackingKey { prunedTerminalTrackingKeys.insert(trackingKey) }
            try store.deleteWindow(id: window.id)
            pruned += 1
        }
        pruned += try pruneOrphanedAgentWindows(
            workspaceID: workspaceID, agents: agentWindows, prunedTerminalTrackingKeys: prunedTerminalTrackingKeys)
        return pruned
    }

    private func windowTrackingKey(_ window: WindowRecord) -> String {
        if window.roleValue == .browser { return "browser:\(window.targetURL ?? "")" }
        if window.roleValue == .terminal {
            let app = window.app.lowercased()
            if let terminalTrackingID = window.terminalTrackingID, !terminalTrackingID.isEmpty {
                return "terminal:\(app):tracking:\(terminalTrackingID)"
            }
        }
        return "\(window.role):none"
    }

    static func nextWindowOrderIndex(existing: [WindowRecord], role: String, orderOffset: Int) -> Int {
        let maxIndex = existing.filter { $0.role == role }.map(\.orderIndex).max() ?? (orderOffset - 1)
        return max(maxIndex + 1, orderOffset)
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
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int(trimmed), pid > 0 else { return nil }
        return pid
    }

    func nowISO8601() -> String { TerminalSessionTimestamp.string(from: Date()) }

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
        case .workspace(let workspace): throw WorkspaceError.invalidArgument(message: "Workspace already exists: \(workspace.displayName)")
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

    func importedRepositoryDefaultBranch(path: String) throws -> String { try git.repositoryDefaultBranch(path: path) }

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
        case working = "working"
        case blocked = "blocked"
        case done = "done"
        case exit = "exit"

        /// The status each signal maps its agent row to. The `.exit` value is not consumed on the exit
        /// path — `handleAgentExit` owns that decision (delete, `.done`, or `.exited`) — but reads
        /// `.exited` so the mapping stays honest.
        var status: AgentWindowStatus {
            switch self {
            case .`init`: .idle
            case .working: .spinning
            case .blocked: .waiting
            case .done: .done
            case .exit: .exited
            }
        }

        var establishesAgentFromEvidence: Bool {
            switch self {
            case .working, .blocked, .done: true
            case .`init`, .exit: false
            }
        }
    }

    func markWorkspaceRunning(_ workspace: WorkspaceRecord, launchedAt: String) throws {
        PortReserver.shared.releasePorts(workspaceID: workspace.id)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: launchedAt)
    }

    func markWorkspaceRunningIfNeeded(_ workspace: WorkspaceRecord, launchedAtFallback: String? = nil) throws {
        guard !workspace.isRunning else {
            PortReserver.shared.releasePorts(workspaceID: workspace.id)
            return
        }
        try markWorkspaceRunning(workspace, launchedAt: workspace.lastLaunchedAt ?? launchedAtFallback ?? nowISO8601())
    }

    func markWorkspaceRunningIfNeeded(workspaceID: String) throws {
        guard let workspace = try store.workspace(id: workspaceID) else { return }
        try markWorkspaceRunningIfNeeded(workspace)
    }

    func clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: String) throws {
        guard try !hasTrackedRuntimeIndicators(workspaceID: workspaceID), let workspace = try store.workspace(id: workspaceID) else { return }
        try markWorkspaceStopped(workspace)
    }

    func markWorkspaceStopped(_ workspace: WorkspaceRecord) throws {
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: false, launchedAt: workspace.lastLaunchedAt)
        if !workspace.isArchived { try PortAllocator(store: store).reserveExistingPorts(workspaceID: workspace.id) }
    }

    func safeFilename(_ raw: String) -> String {
        raw.map { char in
            if char.isLetter || char.isNumber { return char }
            return "_"
        }.reduce("") { $0 + String($1) }
    }

}
