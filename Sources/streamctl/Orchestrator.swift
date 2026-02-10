import Foundation
import appctl

public final class AgentmuxOrchestrator {
    private let store: SQLiteStore
    private let configStore: ConfigStore
    private let git: GitClient
    private let yabai: YabaiAdapter
    private let iterm: Iterm2Adapter
    private let chrome: ChromeAdapter

    public init(
        store: SQLiteStore,
        configStore: ConfigStore,
        git: GitClient = .init(),
        yabai: YabaiAdapter = .init(),
        iterm: Iterm2Adapter = .init(),
        chrome: ChromeAdapter = .init()
    ) {
        self.store = store
        self.configStore = configStore
        self.git = git
        self.yabai = yabai
        self.iterm = iterm
        self.chrome = chrome
    }

    @discardableResult
    public func syncConfig() throws -> AppConfig {
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
                if normalizePath(project.dir) != normalized.config.dir {
                    updatedPaths = true
                }
            } catch {
                fputs("agentmux: skipped project due to error: \(error.localizedDescription)\n", stderr)
                removedInvalid = true
            }
        }
        if removedInvalid || updatedPaths {
            config.projects = normalizedConfigs
            try configStore.save(config)
        }
        let keepIDs = Set(normalizedProjects.map(\.id))
        let existing = try store.projects()
        for project in existing where !keepIDs.contains(project.id) {
            try store.deleteProject(id: project.id)
        }
        for project in normalizedProjects {
            try store.upsert(project: project.record)
            try ensureDefaultWorkspace(for: project.record)
        }
        return config
    }

    public func listProjects() throws -> [ProjectSummary] {
        return try store.projects().map {
            ProjectSummary(id: $0.id, name: $0.name, dir: $0.dir, isGitRepo: $0.isGitRepo, defaultBranch: $0.defaultBranch)
        }
    }

    public func listWorkspaces(projectID: String, includeArchived: Bool = false) throws -> [WorkspaceSummary] {
        let records = try store.workspaces(projectID: projectID, includeArchived: includeArchived)
        return records.map {
            WorkspaceSummary(id: $0.id, name: $0.name, dir: $0.dir, isRunning: $0.isRunning, isArchived: $0.isArchived, isDefault: $0.isDefault)
        }
    }

    public func projectConfig(projectID: String) throws -> ProjectConfig? {
        let config = try configStore.load()
        guard let project = try store.project(id: projectID) else { return nil }
        return config.projects.first { normalizePath($0.dir) == project.dir }
    }

    public func addProject(dir: String) throws -> ProjectRecord {
        var config = try configStore.load()
        let normalizedDir = normalizePath(dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedDir, isDirectory: &isDir), isDir.boolValue else {
            throw AgentmuxError.invalidArgument(message: "Project directory not found: \(normalizedDir)")
        }
        if config.projects.contains(where: { normalizePath($0.dir) == normalizedDir }) {
            throw AgentmuxError.projectAlreadyExists(dir: normalizedDir)
        }
        config.projects.append(ProjectConfig(dir: normalizedDir))
        try configStore.save(config)
        let normalized = try normalize(project: ProjectConfig(dir: normalizedDir))
        try store.upsert(project: normalized.record)
        try ensureDefaultWorkspace(for: normalized.record)
        return normalized.record
    }

    public func updateProjectConfig(_ updated: ProjectConfig) throws {
        var config = try configStore.load()
        let normalizedDir = normalizePath(updated.dir)
        let idx = config.projects.firstIndex { normalizePath($0.dir) == normalizedDir }
        guard let idx else { throw AgentmuxError.missingProject(dir: normalizedDir) }
        config.projects[idx] = updated
        try configStore.save(config)
        let normalized = try normalize(project: updated)
        try store.upsert(project: normalized.record)
        try ensureDefaultWorkspace(for: normalized.record)
    }

    public func updateProjectConfig(projectID: String, update: (inout ProjectConfig) -> Void) throws {
        var config = try configStore.load()
        let normalizedDir = normalizePath(projectID)
        let idx = config.projects.firstIndex { normalizePath($0.dir) == normalizedDir }
        guard let idx else { throw AgentmuxError.missingProject(dir: normalizedDir) }
        var updated = config.projects[idx]
        update(&updated)
        updated.dir = normalizedDir
        config.projects[idx] = updated
        try configStore.save(config)
        let normalized = try normalize(project: updated)
        try store.upsert(project: normalized.record)
        try ensureDefaultWorkspace(for: normalized.record)
    }

    public func removeProject(dir: String) throws {
        var config = try configStore.load()
        let normalizedDir = normalizePath(dir)
        config.projects.removeAll { normalizePath($0.dir) == normalizedDir }
        try configStore.save(config)
        if let project = try store.project(dir: normalizedDir) {
            try store.deleteProject(id: project.id)
        }
    }

    public func createWorkspace(projectID: String, name: String) throws -> WorkspaceRecord {
        guard let project = try store.project(id: projectID) else {
            throw AgentmuxError.missingProject(dir: projectID)
        }
        if let existing = try store.workspace(projectID: projectID, name: name) {
            if !existing.isArchived {
                throw AgentmuxError.workspaceAlreadyExists(project: project.name, workspace: name)
            }
            let revivedDir: String
            let revivedDirname: String?
            let revivedBranch: String?
            if project.isGitRepo {
                let dirname = makeWorkspaceDirname(project: project, workspaceName: name, branch: name)
                revivedDirname = dirname
                let worktreeRoot = try worktreeRoot()
                try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
                revivedDir = worktreeRoot.appendingPathComponent(dirname, isDirectory: true).path
                if !FileManager.default.fileExists(atPath: revivedDir) {
                    try git.createWorktree(path: project.dir, worktreePath: revivedDir, branch: name)
                }
                revivedBranch = name
            } else {
                revivedDir = project.dir
                revivedDirname = nil
                revivedBranch = nil
            }
            let revived = WorkspaceRecord(
                id: existing.id,
                projectID: project.id,
                name: name,
                dir: revivedDir,
                dirname: revivedDirname,
                branch: revivedBranch,
                isDefault: false,
                isArchived: false,
                isRunning: false,
                lastLaunchedAt: nil
            )
            try store.upsert(workspace: revived)
            if let config = try projectConfig(projectID: projectID), let script = config.setupScript, !script.isEmpty {
                try runScript(script, cwd: revived.dir)
            }
            let portRange = try configStore.load().portRange
            _ = try PortAllocator(store: store).allocatePorts(workspaceID: revived.id, count: 10, range: portRange)
            return revived
        }
        let workspaceDir: String
        let workspaceDirname: String?
        let branch: String?
        if project.isGitRepo {
            let dirname = makeWorkspaceDirname(project: project, workspaceName: name, branch: name)
            workspaceDirname = dirname
            let worktreeRoot = try worktreeRoot()
            try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
            workspaceDir = worktreeRoot.appendingPathComponent(dirname, isDirectory: true).path
            try git.createWorktree(path: project.dir, worktreePath: workspaceDir, branch: name)
            branch = name
        } else {
            workspaceDir = project.dir
            workspaceDirname = nil
            branch = nil
        }
        let workspace = WorkspaceRecord(
            id: UUID().uuidString,
            projectID: project.id,
            name: name,
            dir: workspaceDir,
            dirname: workspaceDirname,
            branch: branch,
            isDefault: false,
            isArchived: false,
            isRunning: false,
            lastLaunchedAt: nil
        )
        try store.upsert(workspace: workspace)

        if let config = try projectConfig(projectID: projectID), let script = config.setupScript, !script.isEmpty {
            try runScript(script, cwd: workspaceDir)
        }

        let portRange = try configStore.load().portRange
        _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, count: 10, range: portRange)

        return workspace
    }

    public func launchWorkspace(workspaceID: String) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isArchived else {
            throw AgentmuxError.invalidArgument(message: "Workspace is archived.")
        }
        let config = try projectConfig(projectID: project.id)
        let ports = try store.workspacePorts(workspaceID: workspace.id)
        if ports.count != 10 {
            let portRange = try configStore.load().portRange
            _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, count: 10, range: portRange)
        }

        let env = buildWorkspaceEnv(project: project, workspace: workspace, ports: try store.workspacePorts(workspaceID: workspace.id))

        var newWindows: [WindowRecord] = []
        var windowSnapshot = try yabai.listWindows()

        if let config {
            try launchProcesses(project: project, workspace: workspace, templates: config.processes, env: env)
            newWindows.append(contentsOf: try captureNewWindows(snapshot: windowSnapshot, role: "terminal", appName: "iTerm2", workspaceID: workspace.id, orderOffset: 200))
            windowSnapshot = try yabai.listWindows()

            let browserMatches = try ensureBrowserSessions(project: project, workspace: workspace, sessions: config.browserSessions, env: env)
            newWindows.append(contentsOf: browserMatches)
            newWindows.append(contentsOf: try captureNewWindows(snapshot: windowSnapshot, role: "browser", appName: "Google Chrome", workspaceID: workspace.id, orderOffset: 0))
            windowSnapshot = try yabai.listWindows()
        }

        if let editor = try configStore.load().editor {
            try EditorLauncher.open(editor: editor, directory: workspace.dir)
            newWindows.append(contentsOf: try captureNewWindows(snapshot: windowSnapshot, role: "editor", appName: editorAppName(editor), workspaceID: workspace.id, orderOffset: 100))
        }

        try store.deleteWindows(workspaceID: workspace.id)
        var index = 0
        var seenWindowIDs = Set<Int>()
        let uniqueWindows = newWindows.filter { win in
            guard let id = win.windowID else { return true }
            if seenWindowIDs.contains(id) { return false }
            seenWindowIDs.insert(id)
            return true
        }
        for window in uniqueWindows {
            let stored = WindowRecord(
                id: window.id,
                workspaceID: window.workspaceID,
                app: window.app,
                title: window.title,
                windowID: window.windowID,
                role: window.role,
                orderIndex: index,
                lastSeenAt: window.lastSeenAt
            )
            index += 1
            try store.upsert(window: stored)
        }

        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: nowISO8601())
    }

    public func stopWorkspace(workspaceID: String) throws {
        let (_, workspace) = try resolveWorkspace(id: workspaceID)
        let windows = try store.windows(workspaceID: workspace.id)
        for window in windows {
            if let id = window.windowID {
                _ = try? yabai.closeWindow(id: id)
            }
        }
        let processes = try store.runningProcesses(workspaceID: workspace.id)
        for process in processes {
            if let windowID = process.windowID, process.terminalApp == "iTerm2" {
                _ = try? iterm.closeWindow(id: windowID)
            }
        }
        try store.deleteRunningProcesses(workspaceID: workspace.id)
        try store.deleteWindows(workspaceID: workspace.id)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: false, launchedAt: workspace.lastLaunchedAt)
    }

    public func archiveWorkspace(workspaceID: String) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard !workspace.isDefault else {
            throw AgentmuxError.invalidArgument(message: "Default workspace cannot be archived.")
        }
        try stopWorkspace(workspaceID: workspaceID)
        if let config = try projectConfig(projectID: project.id), let script = config.cleanupScript, !script.isEmpty {
            try runScript(script, cwd: workspace.dir)
        }
        if project.isGitRepo {
            do {
                try git.removeWorktree(path: project.dir, worktreePath: workspace.dir)
            } catch {
                // ignore missing worktree errors
            }
        }
        try PortAllocator(store: store).releasePorts(workspaceID: workspace.id)
        try store.updateWorkspaceArchived(id: workspace.id, isArchived: true)
    }

    public func runningProcesses(workspaceID: String) throws -> [RunningProcessRecord] {
        try store.runningProcesses(workspaceID: workspaceID)
    }

    public func runStatusChecks(workspaceID: String) throws -> [StatusResult] {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard let config = try projectConfig(projectID: project.id) else { return [] }
        let processes = try store.runningProcesses(workspaceID: workspaceID)
        let ports = try store.workspacePorts(workspaceID: workspaceID)
        let env = buildWorkspaceEnv(project: project, workspace: workspace, ports: ports)
        var results: [StatusResult] = []
        for check in config.statusChecks {
            guard let process = processes.first(where: { $0.templateName == check.process }) else { continue }
            let resolvedCommand = applyEnvVars(check.command, env: env)
            let outcome = try runCommandWithTimeout(command: resolvedCommand, cwd: workspace.dir, timeout: check.timeout, env: env)
            let status = outcome.exitCode == 0 ? "green" : "red"
            let result = StatusResult(
                processID: process.id,
                checkName: check.name ?? check.process,
                status: status,
                message: outcome.output.isEmpty ? nil : outcome.output,
                lastRunAt: nowISO8601()
            )
            try store.upsert(statusResult: result)
            results.append(result)
        }
        return results
    }

    public func statusResults(processID: String) throws -> [StatusResult] {
        try store.statusResults(processID: processID)
    }

    public func windows(workspaceID: String) throws -> [WindowRecord] {
        try store.windows(workspaceID: workspaceID)
    }

    public func workspacePorts(workspaceID: String) throws -> [Int] {
        try store.workspacePorts(workspaceID: workspaceID)
    }

    public func focusWorkspace(workspaceID: String) throws {
        let windows = try store.windows(workspaceID: workspaceID).sorted { $0.orderIndex < $1.orderIndex }
        var focused = false
        for window in windows {
            guard let id = window.windowID else { continue }
            let ok = (try? yabai.focusWindow(id: id)) ?? false
            if ok {
                focused = true
                break
            }
        }
        if focused {
            try setActiveWorkspace(id: workspaceID)
        }
    }

    public func listSpaceOptions() throws -> [SpaceOption] {
        let spaces = try yabai.listSpaces()
        return spaces.map { SpaceOption(displayIndex: $0.display, spaceIndex: $0.index) }
            .sorted { lhs, rhs in
                if lhs.displayIndex == rhs.displayIndex {
                    return lhs.spaceIndex < rhs.spaceIndex
                }
                return lhs.displayIndex < rhs.displayIndex
            }
    }

    public func guiHotkey() throws -> String {
        try store.setting(key: SettingsKey.guiHotkey) ?? SettingsKey.defaultGUIHotkey
    }

    public func setGUIHotkey(_ raw: String?) throws {
        try store.setSetting(key: SettingsKey.guiHotkey, value: raw)
    }

    public func guiNextShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiNextShortcut) ?? SettingsKey.defaultGUINextShortcut
    }

    public func setGUINextShortcut(_ raw: String?) throws {
        try store.setSetting(key: SettingsKey.guiNextShortcut, value: raw)
    }

    public func guiPreviousShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiPreviousShortcut) ?? SettingsKey.defaultGUIPreviousShortcut
    }

    public func setGUIPreviousShortcut(_ raw: String?) throws {
        try store.setSetting(key: SettingsKey.guiPreviousShortcut, value: raw)
    }

    public func guiShowShortcut() throws -> String {
        try store.setting(key: SettingsKey.guiShowShortcut) ?? SettingsKey.defaultGUIShowShortcut
    }

    public func setGUIShowShortcut(_ raw: String?) throws {
        try store.setSetting(key: SettingsKey.guiShowShortcut, value: raw)
    }

    public func activeWorkspaceID() throws -> String? {
        try store.setting(key: "active_workspace_id")
    }

    public func setActiveWorkspace(id: String?) throws {
        try store.setSetting(key: "active_workspace_id", value: id)
    }

    private struct NormalizedProject {
        let id: String
        let record: ProjectRecord
        let config: ProjectConfig
    }

    private func normalize(project: ProjectConfig) throws -> NormalizedProject {
        let dir = normalizePath(project.dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw AgentmuxError.invalidArgument(message: "Project directory not found: \(dir)")
        }
        let isGit = git.isRepo(path: dir)
        let branch = isGit ? git.defaultBranch(path: dir) : nil
        let id = dir
        let name = URL(fileURLWithPath: dir).lastPathComponent
        var updatedConfig = project
        updatedConfig.dir = dir
        return NormalizedProject(
            id: id,
            record: ProjectRecord(id: id, name: name, dir: dir, isGitRepo: isGit, defaultBranch: branch),
            config: updatedConfig
        )
    }

    private func ensureDefaultWorkspace(for project: ProjectRecord) throws {
        if let existing = try store.workspace(projectID: project.id, name: "default") {
            if existing.isArchived {
                let revived = WorkspaceRecord(
                    id: existing.id,
                    projectID: project.id,
                    name: existing.name,
                    dir: existing.dir,
                    dirname: existing.dirname,
                    branch: existing.branch,
                    isDefault: true,
                    isArchived: false,
                    isRunning: existing.isRunning,
                    lastLaunchedAt: existing.lastLaunchedAt
                )
                try store.upsert(workspace: revived)
            }
            return
        }
        let workspace = WorkspaceRecord(
            id: UUID().uuidString,
            projectID: project.id,
            name: "default",
            dir: project.dir,
            dirname: nil,
            branch: project.defaultBranch,
            isDefault: true,
            isArchived: false,
            isRunning: false,
            lastLaunchedAt: nil
        )
        try store.upsert(workspace: workspace)
        let portRange = try configStore.load().portRange
        _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, count: 10, range: portRange)
    }

    private func resolveWorkspace(id: String) throws -> (ProjectRecord, WorkspaceRecord) {
        guard let workspace = try store.workspace(id: id) else {
            throw AgentmuxError.invalidArgument(message: "Workspace not found.")
        }
        guard let project = try store.project(id: workspace.projectID) else {
            throw AgentmuxError.missingProject(dir: workspace.projectID)
        }
        return (project, workspace)
    }

    private func runScript(_ script: String, cwd: String) throws {
        _ = try Shell.run(["/bin/bash", "-lc", script], cwd: cwd)
    }

    private func buildWorkspaceEnv(project: ProjectRecord, workspace: WorkspaceRecord, ports: [Int]) -> [String: String] {
        var env: [String: String] = [:]
        for (idx, port) in ports.enumerated() {
            env["PORT\(idx)"] = String(port)
        }
        env["agentmux_WORKSPACE_DIR"] = workspace.dir
        let scopedKey = "agentmux_\(sanitizeEnvKey(project.name))_\(sanitizeEnvKey(workspace.name))_WORKSPACE_DIR"
        env[scopedKey] = workspace.dir
        return env
    }

    private func launchProcesses(project: ProjectRecord, workspace: WorkspaceRecord, templates: [ProcessTemplate], env: [String: String]) throws {
        guard iterm.isAvailable() else {
            throw AgentmuxError.dependencyMissing(message: "iTerm2 is required to launch processes.")
        }
        let runtimeRoot = try runtimeDirectory()
        let workspaceRuntime = URL(fileURLWithPath: runtimeRoot).appendingPathComponent(workspace.id, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRuntime, withIntermediateDirectories: true)

        try store.deleteRunningProcesses(workspaceID: workspace.id)

        for template in templates {
            let name = template.name ?? template.command
            let logFile = workspaceRuntime.appendingPathComponent("\(safeFilename(name)).log").path
            let pidFile = workspaceRuntime.appendingPathComponent("\(safeFilename(name)).pid").path
            let command = shellCommand(
                base: template.command,
                cwd: workspace.dir,
                env: env,
                logFile: logFile,
                pidFile: pidFile
            )
            let window = try iterm.openWindowAndRun(command: command)

            let pid = try? Int(String(contentsOfFile: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))
            let running = RunningProcessRecord(
                id: UUID().uuidString,
                workspaceID: workspace.id,
                templateName: name,
                command: template.command,
                terminalApp: "iTerm2",
                windowID: window.id >= 0 ? window.id : nil,
                pid: pid,
                status: .running,
                logPath: logFile,
                lastOutputAt: nil,
                startedAt: nowISO8601(),
                exitedAt: nil
            )
            try store.upsert(runningProcess: running)
        }

    }

    private func ensureBrowserSessions(project: ProjectRecord, workspace: WorkspaceRecord, sessions: [BrowserSession], env: [String: String]) throws -> [WindowRecord] {
        guard !sessions.isEmpty else { return [] }
        guard chrome.isAvailable() else {
            throw AgentmuxError.dependencyMissing(message: "Google Chrome is required for browser sessions.")
        }
        let yabaiWindows = try yabai.listWindows().filter { $0.app == "Google Chrome" }
        var attached: [WindowRecord] = []
        var seenWindowIDs = Set<Int>()
        for session in sessions {
            guard let rawURL = session.url, !rawURL.isEmpty else { continue }
            let resolved = applyEnvVars(rawURL, env: env)
            let matches = try chrome.windowMatches(forURLPrefix: resolved)
            if matches.isEmpty {
                _ = try chrome.openWindow(url: resolved)
                continue
            }
            for match in matches {
                let matched = yabaiWindows.first { win in
                    guard let title = win.title else { return false }
                    return title == match.title || title.contains(match.title)
                }
                if let matched, !seenWindowIDs.contains(matched.id) {
                    seenWindowIDs.insert(matched.id)
                    attached.append(
                        WindowRecord(
                            id: UUID().uuidString,
                            workspaceID: workspace.id,
                            app: matched.app,
                            title: matched.title,
                            windowID: matched.id,
                            role: "browser",
                            orderIndex: attached.count,
                            lastSeenAt: nowISO8601()
                        )
                    )
                }
            }
        }
        return attached
    }

    private func captureNewWindows(snapshot: [YabaiWindow], role: String, appName: String, workspaceID: String, orderOffset: Int) throws -> [WindowRecord] {
        let after = try yabai.listWindows()
        let snapshotIDs = Set(snapshot.map(\.id))
        let created = after.filter { !snapshotIDs.contains($0.id) && $0.app == appName }
        return created.enumerated().map { idx, win in
            WindowRecord(
                id: UUID().uuidString,
                workspaceID: workspaceID,
                app: win.app,
                title: win.title,
                windowID: win.id,
                role: role,
                orderIndex: orderOffset + idx,
                lastSeenAt: nowISO8601()
            )
        }
    }

    private func runtimeDirectory() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".agentmux", isDirectory: true).appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func shellCommand(base: String, cwd: String, env: [String: String], logFile: String, pidFile: String) -> String {
        let envExports = env.map { key, value in
            return "export \(key)=\"\(value)\""
        }.sorted().joined(separator: "; ")
        let safeCwd = cwd
        let safeLog = logFile
        let safePid = pidFile
        let commands = [
            "cd \"\(safeCwd)\"",
            envExports.isEmpty ? nil : envExports,
            "echo $$ > \"\(safePid)\"",
            "\(base) 2>&1 | tee -a \"\(safeLog)\""
        ].compactMap { $0 }
        let script = commands.joined(separator: "; ")
        let singleQuoted = script.replacing("'", with: "'\\''")
        return "bash -lc '\(singleQuoted)'"
    }

    private func applyEnvVars(_ input: String, env: [String: String]) -> String {
        var output = input
        for (key, value) in env {
            output = output.replacingOccurrences(of: "$\(key)", with: value)
        }
        return output
    }

    private struct CommandOutcome {
        let exitCode: Int32
        let output: String
    }

    private func runCommandWithTimeout(command: String, cwd: String, timeout: Int, env: [String: String]) throws -> CommandOutcome {
        let process = Process()
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = out
        process.standardError = out

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env {
            environment[key] = value
        }
        process.environment = environment

        try process.run()

        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CommandOutcome(exitCode: process.terminationStatus, output: output)
    }

    private func nowISO8601() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func normalizePath(_ path: String) -> String {
        let expanded = expandTilde(path)
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            let suffix = path.dropFirst(2)
            return URL(fileURLWithPath: home).appendingPathComponent(String(suffix)).path
        }
        return path
    }

    private func worktreeRoot() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("agentmux", isDirectory: true).appendingPathComponent("workspaces", isDirectory: true)
    }

    private func makeWorkspaceDirname(project: ProjectRecord, workspaceName: String, branch: String) -> String {
        let base = "\(project.name)-\(workspaceName)-\(branch)"
        let cleaned = base.map { char -> String in
            if char.isLetter || char.isNumber { return String(char) }
            if char == "-" || char == "_" { return String(char) }
            return "-"
        }.joined()
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = String(abs(project.dir.hashValue ^ workspaceName.hashValue ^ branch.hashValue), radix: 16)
        let finalBase = trimmed.isEmpty ? "workspace" : trimmed
        return "\(finalBase)-\(suffix.prefix(6))"
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
}
