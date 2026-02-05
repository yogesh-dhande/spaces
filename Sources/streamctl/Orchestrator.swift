import Foundation
import appctl

public final class StreamOrchestrator {
    private let store: SQLiteStore
    private let yabai: YabaiAdapter

    public init(store: SQLiteStore, yabai: YabaiAdapter = .init()) {
        self.store = store
        self.yabai = yabai
    }

    public func create(projectName: String, streamName: String, worktreePath: String? = nil, displayIndex: Int, spaceIndex: Int) throws -> Stream {
        guard let project = try store.project(named: projectName) else {
            throw StreamctlError.missingProject(name: projectName)
        }
        if let _ = try store.stream(projectID: project.id, name: streamName) {
            throw StreamctlError.streamAlreadyExists(project: projectName, stream: streamName)
        }

        let resolvedWorktree = worktreePath ?? defaultWorktreePath(project: project, streamName: streamName)
        let worktreesDir = URL(fileURLWithPath: resolvedWorktree).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: worktreesDir, withIntermediateDirectories: true)

        let branch = streamName
        try runGit(["-C", project.repoRoot, "worktree", "add", "-b", branch, resolvedWorktree])

        let stream = Stream(
            id: UUID(),
            projectID: project.id,
            name: streamName,
            worktreePath: resolvedWorktree,
            displayIndex: displayIndex,
            spaceIndex: spaceIndex
        )
        try store.upsert(stream: stream)

        let seedIdentity = StreamWindowIdentity(streamID: stream.id, windows: [], updatedAt: nowISO8601())
        try store.upsert(windowIdentity: seedIdentity)

        return stream
    }

    public func updateStream(projectName: String, streamName: String, displayIndex: Int?, spaceIndex: Int?) throws -> Stream {
        let (project, stream) = try resolve(projectName: projectName, streamName: streamName)
        let updated = Stream(
            id: stream.id,
            projectID: project.id,
            name: stream.name,
            worktreePath: stream.worktreePath,
            displayIndex: displayIndex ?? stream.displayIndex,
            spaceIndex: spaceIndex ?? stream.spaceIndex
        )
        try store.upsert(stream: updated)
        return updated
    }

    public func destroy(projectName: String, streamName: String, removeBranch: Bool = false) throws {
        let (project, stream) = try resolve(projectName: projectName, streamName: streamName)
        let identity = try store.windowIdentity(streamID: stream.id)
        if let identity {
            for win in identity.windows {
                _ = try? yabai.closeWindow(id: win.id)
            }
        }

        do {
            try runGit(["-C", project.repoRoot, "worktree", "remove", "--force", stream.worktreePath])
        } catch let StreamctlError.gitCommandFailed(message) {
            let lower = message.lowercased()
            let ignorable =
                lower.contains("does not exist") ||
                lower.contains("is not a working tree") ||
                lower.contains("not a worktree") ||
                lower.contains("not found")
            if !ignorable {
                throw StreamctlError.gitCommandFailed(message: message)
            }
        }

        if removeBranch {
            _ = try? runGit(["-C", project.repoRoot, "branch", "-D", stream.name])
        }

        try store.deleteStream(id: stream.id)
    }

    public func show(projectName: String, streamName: String) throws {
        let (_, stream) = try resolve(projectName: projectName, streamName: streamName)
        try ensureValidWorktree(stream: stream)

        guard let identity = try store.windowIdentity(streamID: stream.id) else {
            throw StreamctlError.invalidArgument(message: "No captured windows for stream. Run 'stream capture' first.")
        }

        print("[stream:\(stream.name)] show windows=\(identity.windows.count)")
        var focusedCount = 0
        for win in identity.windows {
            print("[stream:\(stream.name)] show focus id=\(win.id) app=\(win.app) space=\(win.space) display=\(win.display)")
            let focused = (try? yabai.focusWindow(id: win.id)) ?? false
            print("[stream:\(stream.name)] show focus result=\(focused ? "ok" : "fail") id=\(win.id)")
            if focused { focusedCount += 1 }
        }

        if focusedCount == 0 {
            print("[stream:\(stream.name)] WARN: no compatible windows could be focused. Try closing/reopening the target app windows, then re-run capture.")
        }

        try store.markActive(stream: stream)
    }

    public func capture(projectName: String, streamName: String) throws {
        let (_, stream) = try resolve(projectName: projectName, streamName: streamName)
        let windows = try yabai.listWindows(spaceIndex: stream.spaceIndex)
        let identities = windows.filter { win in
            win.space == stream.spaceIndex && !win.isSticky
        }.map { win in
            WindowIdentity(id: win.id, app: win.app, title: win.title, space: win.space, display: win.display)
        }
        let identity = StreamWindowIdentity(streamID: stream.id, windows: identities, updatedAt: nowISO8601())
        try store.upsert(windowIdentity: identity)
        print("[stream:\(stream.name)] capture space=\(stream.spaceIndex) windows=\(windows.count) kept=\(identities.count)")
        for win in windows {
            print("[stream:\(stream.name)] capture candidate id=\(win.id) app=\(win.app) space=\(win.space) sticky=\(win.isSticky) visible=\(win.isVisible) hidden=\(win.isHidden) fullscreen=\(win.isNativeFullscreen)")
        }
    }

    public func list(projectName: String) throws -> [StreamSummary] {
        guard let project = try store.project(named: projectName) else {
            throw StreamctlError.missingProject(name: projectName)
        }
        return try store.streams(projectID: project.id)
    }

    public func listProjects() throws -> [Project] {
        try store.projects()
    }

    public func createProject(name: String, repoRoot: String) throws -> Project {
        if try store.project(named: name) != nil {
            throw StreamctlError.projectAlreadyExists(name: name)
        }

        let project = Project(
            id: UUID(),
            name: name,
            repoRoot: repoRoot
        )
        try store.upsert(project: project)
        return project
    }

    public func updateProject(name: String, repoRoot: String?) throws -> Project {
        guard let current = try store.project(named: name) else {
            throw StreamctlError.missingProject(name: name)
        }

        let project = Project(
            id: current.id,
            name: current.name,
            repoRoot: repoRoot ?? current.repoRoot
        )
        try store.upsert(project: project)
        return project
    }

    public func deleteProject(name: String) throws {
        guard try store.project(named: name) != nil else {
            throw StreamctlError.missingProject(name: name)
        }
        try store.deleteProject(name: name)
    }

    public func listActive() throws -> [ActiveStreamSummary] {
        try store.activeStreams()
    }

    public func doctor(projectName: String? = nil, streamName: String? = nil) throws -> [StreamDoctorReport] {
        let yabaiAvailable = yabai.isAvailable()
        let projects: [Project]
        if let projectName {
            guard let project = try store.project(named: projectName) else {
                throw StreamctlError.missingProject(name: projectName)
            }
            projects = [project]
        } else {
            projects = try store.projects()
        }

        var reports: [StreamDoctorReport] = []
        for project in projects {
            let streams = try store.fullStreams(projectID: project.id)
            for stream in streams where streamName == nil || stream.name == streamName {
                let identity = try store.windowIdentity(streamID: stream.id)
                let expected = identity?.windows.count ?? 0
                var found = 0
                var missing: [Int] = []
                if let identity {
                    for win in identity.windows {
                        let exists = ((try? yabai.windowExists(id: win.id)) ?? false)
                        if exists {
                            found += 1
                        } else {
                            missing.append(win.id)
                        }
                    }
                }

                reports.append(
                    StreamDoctorReport(
                        projectName: project.name,
                        streamName: stream.name,
                        worktreePath: stream.worktreePath,
                        displayIndex: stream.displayIndex,
                        spaceIndex: stream.spaceIndex,
                        yabaiAvailable: yabaiAvailable,
                        windowsFound: found,
                        windowsExpected: expected,
                        missingWindowIDs: missing
                    )
                )
            }
        }

        return reports.sorted {
            if $0.projectName == $1.projectName {
                return $0.streamName < $1.streamName
            }
            return $0.projectName < $1.projectName
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

    private func resolve(projectName: String, streamName: String) throws -> (Project, Stream) {
        guard let project = try store.project(named: projectName) else {
            throw StreamctlError.missingProject(name: projectName)
        }
        guard let stream = try store.stream(projectID: project.id, name: streamName) else {
            throw StreamctlError.missingStream(project: projectName, stream: streamName)
        }
        return (project, stream)
    }

    private func ensureValidWorktree(stream: Stream) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stream.worktreePath, isDirectory: &isDir), isDir.boolValue else {
            throw StreamctlError.invalidWorktree(path: stream.worktreePath)
        }
    }

    private func defaultWorktreePath(project: Project, streamName: String) -> String {
        let rootURL = URL(fileURLWithPath: project.repoRoot)
        return rootURL
            .appendingPathComponent(".agentmux-worktrees", isDirectory: true)
            .appendingPathComponent(streamName, isDirectory: true)
            .path
    }

    private func nowISO8601() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        let out = Pipe()
        let err = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.standardOutput = out
        process.standardError = err

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            throw StreamctlError.gitCommandFailed(message: message)
        }
    }
}
