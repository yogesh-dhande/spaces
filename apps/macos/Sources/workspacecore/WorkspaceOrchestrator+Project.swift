import Foundation
import spacesterminalcore
import systembridge

extension WorkspaceOrchestrator {
    public func listProjects() throws -> [ProjectSummary] {
        return try store.projects().map {
            ProjectSummary(id: $0.id, name: $0.name, dir: $0.dir, isGitRepo: $0.isGitRepo, defaultBranch: $0.defaultBranch)
        }
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
        return try configuredProjectRecord(baseRecord: normalizeDir(id: UUID().uuidString, normalizedDir)) { project in
            importedDocument?.applying(to: &project)
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
        let record = try configuredProjectRecord(baseRecord: normalizeDir(id: UUID().uuidString, normalizedDir)) { project in
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
        let baseRecord = try normalizeDir(id: UUID().uuidString, normalizedDir)
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
            let defaultBranch = try importedRepositoryDefaultBranch(path: plan.destination.path)
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

    /// Loads a git repository's `spaces.yaml` for the add-project preview without cloning into the
    /// managed repo root. The full clone is deferred to Create, so this only fetches the single file
    /// from the repository's declared default branch and reports managed-directory collisions from
    /// the local filesystem.
    public func previewGitProject(gitURL: String) throws -> GitProjectPreview {
        let plan = try gitProjectImportPlan(gitURL: gitURL)
        let replacementCandidates = try managedGitProjectImportReplacementCandidates(plan: plan)
        let file = try git.readRemoteDefaultBranchFile(gitURL: plan.gitURL, path: SpacesYAMLService.fileName)
        let importedDocument = try file.contents.map { try SpacesYAMLService.decode($0) }
        let baseRecord = ProjectRecord(
            id: plan.project.id, name: plan.project.name, dir: plan.project.dir, isGitRepo: true, defaultBranch: file.defaultBranch)
        let record = try configuredProjectRecord(baseRecord: baseRecord) { project in importedDocument?.applying(to: &project) }
        return GitProjectPreview(project: record, replacementCandidates: replacementCandidates, spacesYAMLFound: importedDocument != nil)
    }

    public func managedGitProjectImportReplacementCandidates(gitURL: String) throws -> [ManagedDirectoryReplacementCandidate] {
        try managedGitProjectImportReplacementCandidates(plan: gitProjectImportPlan(gitURL: gitURL))
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
            id: prepared.defaultWorkspace.id, projectID: record.id, dir: prepared.defaultWorkspace.dir, dirname: prepared.defaultWorkspace.dirname,
            branch: prepared.defaultWorkspace.branch, baseBranch: prepared.defaultWorkspace.baseBranch, isDefault: true,
            isHidden: prepared.defaultWorkspace.isHidden, isRunning: false, lastLaunchedAt: nil, notes: prepared.defaultWorkspace.notes)
        try store.upsert(project: record)
        do {
            try store.upsert(workspace: defaultWorkspace)
            try seedWorkspaceSettings(project: record, workspace: defaultWorkspace)
            let appConfig = try store.appConfig()
            let portDefinitions = try store.workspaceServiceDefinitions(workspaceID: defaultWorkspace.id)
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

    /// Removes the project identified by its stable id. This is the deletion entry point for
    /// callers that already hold the project's identity (the Device API delete handler resolves
    /// the record by id before deleting). Deleting by id — the `projects` primary key — instead of
    /// re-resolving by directory removes the dependency on the stored `dir` round-tripping through
    /// `normalizePath`: a project whose recorded directory no longer canonicalizes to itself (for
    /// example a directory that gained a Git repository or moved on disk) is still reliably deleted
    /// rather than leaving `removeProject(dir:)` to silently match nothing.
    public func removeProject(id: String) throws {
        guard let project = try store.project(id: id) else { throw WorkspaceError.missingProject(dir: id) }
        try removeProject(project)
    }

    /// Removes the project registered at `dir`, when one is registered there. Kept for callers that
    /// only know a directory (fixture cleanup and directory-scoped harnesses); id-based deletion is
    /// the path the product's delete action uses.
    public func removeProject(dir: String) throws {
        let normalizedDir = normalizePath(dir)
        guard let project = try store.project(dir: normalizedDir) else { return }
        try removeProject(project)
    }

    /// Deleting a project stops and removes every workspace in it, so it holds the project's gate and
    /// every one of those workspaces' lifecycle gates for the whole teardown. The project key blocks a
    /// `createWorkspace` from adding a workspace to a project that is going away (no workspace key could
    /// cover a workspace that does not exist yet); the workspace keys block a launch, stop, process or
    /// agent start, or terminal open from stranding runtime in a workspace being removed. Both are
    /// claimed before any destructive work, so a conflict rejects the delete instead of half-doing it.
    private func removeProject(_ project: ProjectRecord) throws {
        try withProjectLifecycleLock(projectID: project.id) {
            // Both reads happen under the project gate, never before it. A workspace list read outside the
            // gate can miss a `createWorkspace` that lands between the read and the claim: its record would
            // be cascaded away by `store.deleteProject` while its runtime and worktree — which only this
            // teardown removes, and only for the workspaces it snapshotted — were left behind. Re-reading
            // the project itself keeps a second delete that queued behind this one from working off a
            // record that has already been removed.
            guard let project = try store.project(id: project.id) else { return }
            let workspaces = try store.workspaces(projectID: project.id)
            return try withWorkspaceLifecycleLocks(workspaceIDs: workspaces.map(\.id)) { try removeProjectUnlocked(project, workspaces: workspaces) }
        }
    }

    private func removeProjectUnlocked(_ project: ProjectRecord, workspaces: [WorkspaceRecord]) throws {
        // Finalize every coding-agent row in the project through the termination chokepoint BEFORE the
        // bulk store delete. `agent_subscriptions.agent_session_id` is `ON DELETE RESTRICT`, so
        // `deleteProject`'s raw `DELETE FROM agent_sessions` throws if the scope still holds any agent
        // row with inbound watch edges — including an `.exited`-kept row whose watcher (possibly in
        // another, surviving project) has not unsubscribed. Routing each row through `.destroyed`
        // delivers the exited notice those outside watchers are owed, drops the inbound edges (so the
        // delete succeeds), terminates the agent's backing terminal, and tears down each terminal's own
        // outgoing watch state.
        for workspace in workspaces {
            for agent in try store.agentWindows(workspaceID: workspace.id) {
                try finalizeAgentRow(agent, reason: .destroyed(terminateTerminalSession: true))
            }
        }
        // Mutate the database BEFORE any irreversible filesystem work: a RESTRICT/consistency failure
        // then surfaces while the worktrees still exist, instead of after they were already removed from
        // disk and the project left half-deleted.
        try store.deleteProject(id: project.id)
        try removeManagedGitWorktreesIfNeeded(project: project, workspaces: workspaces)
        try removeManagedGitWorkspaceDirectoriesIfNeeded(project: project)
        try removeManagedProjectDirectoryIfNeeded(project: project)
    }

    func configuredProjectRecord(baseRecord: ProjectRecord, update: (inout ProjectRecord) -> Void) throws -> ProjectRecord {
        var record = baseRecord
        update(&record)
        let previousPorts = baseRecord.ports
        let previousProcesses = baseRecord.processes
        let previousAgentLaunchers = baseRecord.agentLaunchers
        record = ProjectRecord(
            id: baseRecord.id, name: baseRecord.name, dir: baseRecord.dir, isGitRepo: baseRecord.isGitRepo, defaultBranch: baseRecord.defaultBranch,
            setupScript: record.setupScript, stopScript: record.stopScript, ports: record.ports, processes: record.processes,
            browserSessions: record.browserSessions, agentLaunchers: record.agentLaunchers)
        record.ports = normalizeServiceDefinitionIDs(previous: previousPorts, updated: record.ports)
        record.processes = normalizeProcessTemplateIDs(previous: previousProcesses, updated: record.processes)
        record.agentLaunchers = normalizeAgentLauncherIDs(previous: previousAgentLaunchers, updated: record.agentLaunchers)
        record.ports = try normalizedServiceDefinitions(record.ports)
        try validateProcessTemplates(record.processes)
        try validateUniqueConfiguredFocusNames(
            processes: record.processes, browserSessions: record.browserSessions, agentLaunchers: record.agentLaunchers)
        return record
    }

    func createImportedGitDefaultWorkspaceOnDisk(project: ProjectRecord, branch: String) throws -> WorkspaceRecord {
        let worktreeRoot = try worktreeRoot(project: project)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let workspaceDir = worktreeRoot.appendingPathComponent(branch, isDirectory: true).path
        try git.createWorktree(path: project.dir, worktreePath: workspaceDir, branch: branch, baseBranch: branch)
        return WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, dir: workspaceDir, dirname: branch, branch: branch, baseBranch: branch, isDefault: true,
            isRunning: false, lastLaunchedAt: nil)
    }

    func applyProjectTemplateToAllWorkspaces(project: ProjectRecord) throws {
        let workspaces = try store.workspaces(projectID: project.id)
        for workspace in workspaces { try applyProjectTemplate(project, to: workspace, syncPorts: true) }
    }

    func applyProjectTemplate(_ project: ProjectRecord, to workspace: WorkspaceRecord, syncPorts: Bool) throws {
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
        settings.ports = normalizeServiceDefinitionIDs(previous: previousPorts, updated: settings.ports)
        settings.ports = try normalizedServiceDefinitions(settings.ports)
        settings.processes = normalizeProcessTemplateIDs(previous: previousProcesses, updated: settings.processes)
        settings.agentLaunchers = normalizeAgentLauncherIDs(previous: previousAgentLaunchers, updated: settings.agentLaunchers)
        try validateProcessTemplates(settings.processes)
        try validateWorkspaceFocusNames(
            workspaceID: workspace.id, processes: settings.processes, browserSessions: settings.browserSessions,
            agentLaunchers: settings.agentLaunchers, agentWindows: try store.agentWindows(workspaceID: workspace.id))
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: settings.stopScript)
        try store.setWorkspaceServiceDefinitions(workspaceID: workspace.id, definitions: settings.ports)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: settings.processes)
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: settings.browserSessions)
        try store.setWorkspaceAgentLaunchers(workspaceID: workspace.id, launchers: settings.agentLaunchers)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: nowISO8601())
        if syncPorts {
            let appConfig = try store.appConfig()
            _ = try PortAllocator(store: store).syncPorts(workspaceID: workspace.id, definitions: settings.ports, range: appConfig.portRange)
        }
    }

    func managedGitProjectImportReplacementCandidates(plan: GitProjectImportPlan) throws -> [ManagedDirectoryReplacementCandidate] {
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

    func validateManagedGitProjectImportDirectoriesAreUnowned(plan: GitProjectImportPlan) throws {
        try validateManagedDirectoryIsUnowned(path: plan.destination.path)
        try validateManagedDirectoryIsUnowned(path: worktreeRoot(project: plan.project).path)
    }

    func replaceManagedGitProjectImportDirectoriesIfNeeded(plan: GitProjectImportPlan, allowReplacement: Bool) throws {
        let candidates = try managedGitProjectImportReplacementCandidates(plan: plan)
        guard !candidates.isEmpty else { return }
        guard allowReplacement else {
            throw WorkspaceError.invalidArgument(
                message: "Managed project import folders already exist: \(candidates.map(\.path).joined(separator: ", "))")
        }
        let orderedCandidates = candidates.sorted { lhs, rhs in lhs.kind == .workspaceDirectory && rhs.kind == .projectRepository }
        for candidate in orderedCandidates { try removeReplaceableManagedDirectory(candidate) }
    }

    func removeRegisteredGitWorktreeForReplacementIfNeeded(path: String) throws {
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

    func removeManagedGitWorkspaceDirectoriesIfNeeded(project: ProjectRecord) throws {
        guard project.isGitRepo else { return }
        let root = try worktreeRoot(project: project)
        let normalizedRoot = normalizePath(root.path)
        guard isManagedWorkspacesDirectory(path: normalizedRoot, allowEqual: true) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedRoot, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        try FileManager.default.removeItem(atPath: normalizedRoot)
    }

    func removeManagedGitWorktreesIfNeeded(project: ProjectRecord, workspaces: [WorkspaceRecord]) throws {
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

    func removePreparedManagedGitWorkspaceRootIfUnowned(project: ProjectRecord) throws {
        guard project.isGitRepo else { return }
        let root = try worktreeRoot(project: project)
        guard isManagedWorkspaceEntryPath(root.path) else { return }
        try removePreparedManagedDirectoryIfUnowned(path: root.path)
    }
}
