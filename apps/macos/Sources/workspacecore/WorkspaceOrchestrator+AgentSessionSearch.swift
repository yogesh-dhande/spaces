import Foundation
import spacessessionindex
import spacesterminalcore

/// A past coding-agent conversation found in an agent's own store, named by what resuming it needs.
public struct AgentSessionReference: Sendable, Equatable {
    public let agent: CodingAgent
    public let sessionKey: String
    public let workingDirectory: String?

    public init(agent: CodingAgent, sessionKey: String, workingDirectory: String?) {
        self.agent = agent
        self.sessionKey = sessionKey
        self.workingDirectory = workingDirectory
    }
}

/// The workspace a resumed session opens in.
public struct AgentSessionDestination: Sendable, Equatable {
    public let projectID: String
    public let projectName: String
    public let workspaceID: String
    public let workspaceName: String
    public let workspaceDir: String
}

public struct RunningAgentSession: Sendable, Equatable {
    public let workspaceID: String
    public let terminalSessionID: String
}

/// How a resume ended: in the terminal that was already running the conversation (`launchedSession` nil)
/// or in one it just launched.
public struct AgentSessionResumption: Sendable {
    public let workspaceID: String
    public let sessionID: String
    public let launchedSession: TerminalServiceSessionSummary?
}

/// What this device's own state says about a session found in an agent's store.
public struct AgentSessionContext: Sendable, Equatable {
    public let destination: AgentSessionDestination
    /// The terminal already running this conversation, in any workspace.
    public let running: RunningAgentSession?
    public var runningTerminalSessionID: String? { running?.terminalSessionID }
    /// The name of the thread pinned for this conversation, in any workspace.
    public let pinnedName: String?
    /// The pin `pinnedName` comes from; a pinned conversation resumes through it.
    public let pinID: String?
    /// The session's folder is known and no longer exists.
    public let folderIsMissing: Bool

    /// Resuming is impossible: the agent resumes only from the folder it ran in and that folder is gone.
    /// A session that is already running resumes by focusing it, so it never counts as lost.
    public func cannotResume(agent: CodingAgent) -> Bool { runningTerminalSessionID == nil && folderIsMissing && agent.resumesOnlyFromOriginalFolder }
}

extension WorkspaceOrchestrator {
    /// Everything the device knows about each session, from one read of its projects, workspaces, agent
    /// rows and pins, so a page of results costs one pass over that state and not one per result.
    public func agentSessionContexts(for references: [AgentSessionReference]) throws -> [AgentSessionContext] {
        guard !references.isEmpty else { return [] }
        let projects = try store.projects()
        var workspacesByProject: [String: [WorkspaceRecord]] = [:]
        for project in projects { workspacesByProject[project.id] = try store.workspaces(projectID: project.id) }
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let allWorkspaces = workspacesByProject.values.joined()
        let agentWindows = try store.agentWindowsByWorkspace().values.joined().filter { $0.sessionKey != nil }
        let pins = try store.pinnedThreadsByWorkspace().values.joined()

        return try references.map { reference in
            let pin = pins.first { $0.sessionKey == reference.sessionKey && CodingAgent.matching(command: $0.launchCommand) == reference.agent }
            // A pinned conversation resumes in the pin's workspace, where the launch attaches the pin and
            // gives the row its name, wherever the folder maps.
            let pinnedDestination = pin.flatMap { pin in
                allWorkspaces.first { $0.id == pin.workspaceID }.flatMap { workspace in
                    projectsByID[workspace.projectID].map { Self.destination(project: $0, workspace: workspace) }
                }
            }
            let running = agentWindows.first {
                $0.sessionKey == reference.sessionKey && agentKind(of: $0) == reference.agent && builtInAgentIsRunning($0)
            }
            return AgentSessionContext(
                destination: try pinnedDestination
                    ?? destination(forWorkingDirectory: reference.workingDirectory, projects: projects, workspacesByProject: workspacesByProject),
                running: running.flatMap { row in
                    builtInAgentSessionID(for: row).map { RunningAgentSession(workspaceID: row.workspaceID, terminalSessionID: $0) }
                }, pinnedName: pin?.name, pinID: pin?.id,
                folderIsMissing: (pin?.workingDirectory ?? reference.workingDirectory).map { !Self.directoryExists($0) } ?? false)
        }
    }

    /// The index filter for the conversations that open in a project, by the same rule as
    /// `destination(forWorkingDirectory:)`; nil when the device has no such project.
    ///
    /// Agents record a folder either symlink-resolved or as typed, so every folder is listed in both forms.
    /// The result is exact except where project roots overlap in ways the folder rule cannot express; the
    /// caller keeps only the hits whose destination is this project.
    public func agentSessionFolderFilter(forProjectID projectID: String) throws -> AgentSessionFolderFilter? {
        let projects = try store.projects()
        guard let project = projects.first(where: { $0.id == projectID }) else { return nil }
        let ordinary = projects.filter { $0.kind != .home }
        var workspacesByProject: [String: [WorkspaceRecord]] = [:]
        for project in projects { workspacesByProject[project.id] = try store.workspaces(projectID: project.id) }
        let pinsByWorkspace = try store.pinnedThreadsByWorkspace()
        func pinnedKeys(in projectIDs: (String) -> Bool) -> [String] {
            workspacesByProject.filter { projectIDs($0.key) }.values.joined().flatMap { pinsByWorkspace[$0.id] ?? [] }.map(\.sessionKey)
        }
        let includedKeys = pinnedKeys { $0 == project.id }
        let excludedKeys = pinnedKeys { $0 != project.id }

        func workspaceDirs(_ project: ProjectRecord) -> [String] { (workspacesByProject[project.id] ?? []).map(\.dir) }
        func roots(_ project: ProjectRecord) -> [String] { [project.dir] + [try? worktreeRoot(project: project).path].compactMap { $0 } }

        if project.kind == .home {
            return AgentSessionFolderFilter(
                includedFolders: nil, excludedFolders: bothForms(of: ordinary.flatMap { workspaceDirs($0) + roots($0) }), includesUnknownFolder: true,
                includedSessionKeys: includedKeys, excludedSessionKeys: excludedKeys)
        }
        let included = bothForms(of: workspaceDirs(project) + roots(project))
        let nestedElsewhere = ordinary.filter { $0.id != project.id }.flatMap(workspaceDirs).filter { dir in
            included.contains { isPath(dir, inside: $0) }
        }
        return AgentSessionFolderFilter(
            includedFolders: included, excludedFolders: bothForms(of: nestedElsewhere), includedSessionKeys: includedKeys,
            excludedSessionKeys: excludedKeys)
    }

    private func bothForms(of paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.flatMap { [normalizePath($0), standardizePathPreservingSymlinks($0)] }.filter { seen.insert($0).inserted }
    }

    /// Resumes a past conversation from an agent's store, or reports the terminal already running it so the
    /// client focuses that instead of launching a second copy.
    ///
    /// A folder that is gone fails for the agents that resume only from the folder they ran in (the reason
    /// carries the session id, which the user can cite in a new session for context). The others resume in
    /// the destination workspace's directory.
    public func resumeAgentSession(_ reference: AgentSessionReference) throws -> AgentSessionResumption {
        guard let context = try agentSessionContexts(for: [reference]).first else {
            throw WorkspaceError.invalidArgument(message: "Session \(reference.sessionKey) was not found.")
        }
        if let running = context.running {
            return AgentSessionResumption(workspaceID: running.workspaceID, sessionID: running.terminalSessionID, launchedSession: nil)
        }
        if context.cannotResume(agent: reference.agent) {
            throw WorkspaceError.invalidArgument(message: "Folder no longer exists, can't resume. Session id: \(reference.sessionKey)")
        }
        // A pin keeps the launch command the conversation last ran with (flags, environment, a Codex
        // profile), so opening it here launches what clicking the pin would. Its folder follows the same
        // missing-folder rule as any other result, so a pinned Codex conversation whose folder was deleted
        // still resumes in the workspace's folder.
        let pin = try context.pinID.flatMap { try store.pinnedThread(id: $0) }
        let launchCommand = pin?.launchCommand ?? reference.agent.primaryCommandName
        let folder = pin?.workingDirectory ?? reference.workingDirectory
        let session = try createWorkspaceAgentSession(
            workspaceID: context.destination.workspaceID,
            command: CodingAgent.resumeCommand(launchCommand: launchCommand, sessionKey: reference.sessionKey), title: nil,
            recordedLaunchCommand: launchCommand, workingDirectory: folder.flatMap { Self.directoryExists($0) ? $0 : nil },
            resumedAgentSessionKey: reference.sessionKey)
        return AgentSessionResumption(workspaceID: context.destination.workspaceID, sessionID: session.id, launchedSession: session)
    }

    /// The workspace a session opens in: the deepest non-home workspace containing the folder, else the
    /// default workspace of a project whose directory or worktree root contains it (a deleted worktree's
    /// folder still belongs to its project), else the home workspace. Unlike `resolveWorkspaceID`, a folder
    /// that belongs to nothing is not an error, since a conversation can come from anywhere.
    private func destination(forWorkingDirectory cwd: String?, projects: [ProjectRecord], workspacesByProject: [String: [WorkspaceRecord]]) throws
        -> AgentSessionDestination
    {
        let ordinary = projects.filter { $0.kind != .home }
        if let cwd {
            let containing = ordinary.flatMap { project in (workspacesByProject[project.id] ?? []).map { (project, $0) } }.filter {
                isPath(cwd, inside: $0.1.dir, allowEqual: true)
            }.max { normalizePath($0.1.dir).count < normalizePath($1.1.dir).count }
            if let containing { return Self.destination(project: containing.0, workspace: containing.1) }
            for project in ordinary {
                let roots = [project.dir] + [try? worktreeRoot(project: project).path].compactMap { $0 }
                guard roots.contains(where: { isPath(cwd, inside: $0, allowEqual: true) }),
                    let workspace = (workspacesByProject[project.id] ?? []).first(where: \.isDefault)
                else { continue }
                return Self.destination(project: project, workspace: workspace)
            }
        }
        guard let home = projects.first(where: { $0.kind == .home }), let workspace = workspacesByProject[home.id]?.first else {
            throw WorkspaceError.invalidArgument(message: "This device has no home workspace to resume in.")
        }
        return Self.destination(project: home, workspace: workspace)
    }

    private static func destination(project: ProjectRecord, workspace: WorkspaceRecord) -> AgentSessionDestination {
        AgentSessionDestination(
            projectID: project.id, projectName: project.name, workspaceID: workspace.id,
            workspaceName: project.kind.workspaceDisplayName(branch: workspace.branch, dir: workspace.dir), workspaceDir: workspace.dir)
    }

    /// The agent an agent row runs: its detected kind, else the agent its launch command names.
    private func agentKind(of record: AgentWindowRecord) -> CodingAgent? {
        if let kind = resolvedAgentKind(record).flatMap(TerminalDetectedAgentKind.init(rawValue:)) { return kind.agent }
        return record.launchCommand.flatMap { CodingAgent.matching(command: $0) }
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
